import os
import plistlib
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def make_png(path):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress((b"\0" + b"\x00\x76\xcf\xff" * 16) * 16))
        + chunk(b"IEND", b"")
    )


class ChromeModeTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.work = Path(work.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.home = self.work / "home"
        self.home.mkdir()
        self.env = {**os.environ, "HOME": str(self.home),
                    "PATH": f"{self.bin}:{SYSTEM_PATH}"}
        self.env.pop("PYTHONPATH", None)
        self.env.pop("PYTHONHOME", None)
        (self.bin / "python3").symlink_to(sys.executable)

    def run_script(self, name, *args, answers=None):
        return subprocess.run(
            ["/bin/bash", str(self.work / name), *args], capture_output=True,
            text=True, input=answers, env=self.env, cwd=self.work, timeout=45,
        )

    def prepare_cli(self):
        shutil.copyfile(ROOT / "cloning-cli.sh", self.work / "cloning-cli.sh")
        chrome = self.home / "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        chrome.parent.mkdir(parents=True)
        chrome.touch(mode=0o755)
        icon = self.work / "icon.png"
        make_png(icon)
        return str(icon)

    @unittest.skipUnless(sys.platform == "darwin", "uses macOS icon and DMG tools")
    def test_chrome_build_without_node_or_pillow(self):
        icon = self.prepare_cli()
        # Ensure the active interpreter cannot pick up an installed Pillow.
        self.env["PYTHONNOUSERSITE"] = "1"
        (self.bin / "python3").unlink()
        python = self.bin / "python3"
        python.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} -S \"$@\"\n")
        python.chmod(0o755)
        old_output = self.work / "output/GitHub"
        old_output.mkdir(parents=True)
        (old_output / "previous-build").touch()
        result = self.run_script(
            "cloning-cli.sh", "--url", "https://github.com/",
            "--chrome-only", "--icon", icon,
            "--dmg-output", "custom.dmg",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr.count("Pillow no esta disponible"), 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn("Generando app con Nativefier", result.stdout)
        self.assertTrue((old_output / "previous-build").is_file())
        output = self.work / "output/GitHub (Chrome)"
        self.assertEqual(sorted(p.name for p in output.iterdir()), ["GitHub.app"])
        contents = output / "GitHub.app/Contents"
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleName"], "GitHub")
        self.assertEqual(info["CFBundleDisplayName"], "GitHub")
        self.assertEqual(info["CFBundleExecutable"], "GitHub")
        self.assertEqual(info["CFBundleIdentifier"], "com.local.webclone.github.chrome")
        self.assertNotIn("NSPrincipalClass", info)
        self.assertTrue((contents / "Resources" / info["CFBundleIconFile"]).is_file())
        executable = contents / "MacOS" / info["CFBundleExecutable"]
        self.assertTrue(os.access(executable, os.X_OK))
        self.assertIn("--app=${APP_URL}", executable.read_text())
        self.assertTrue((self.work / "custom.dmg").is_file())

    @unittest.skipUnless(sys.platform == "darwin", "uses macOS icon tools")
    def test_generate_pwa_still_builds_both(self):
        icon = self.prepare_cli()
        for tool, script in {
            "node": "exit 0",
            "npx": 'mkdir -p "Fixture-darwin-arm64/Fixture.app/Contents"',
        }.items():
            executable = self.bin / tool
            executable.write_text(f"#!/bin/sh\n{script}\n")
            executable.chmod(0o755)
        result = self.run_script(
            "cloning-cli.sh", "--url", "https://example.com/", "--name", "Fixture",
            "--generate-pwa", "--no-dmg", "--icon", icon,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = self.work / "output/Fixture"
        self.assertEqual(
            sorted(p.name for p in output.iterdir()), ["Fixture PWA.app", "Fixture.app"]
        )
        with (output / "Fixture PWA.app/Contents/Info.plist").open("rb") as plist:
            self.assertEqual(plistlib.load(plist)["CFBundleIdentifier"],
                             "com.local.webclone.fixture.pwa")

    def test_suggest_name_does_not_generate_output(self):
        shutil.copyfile(ROOT / "cloning-cli.sh", self.work / "cloning-cli.sh")
        for url, expected in [
            ("https://www.GITHUB.com/settings", "GitHub"),
            ("https://github.com.example/", "Github Com Example"),
        ]:
            result = self.run_script("cloning-cli.sh", "--suggest-name", url)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)
        self.assertFalse((self.work / "output").exists())

    def test_wizard_mode_routes(self):
        shutil.copyfile(ROOT / "cloning-website-to-dmg.sh", self.work / "cloning-website-to-dmg.sh")
        (self.work / "cloning-cli.sh").write_text(
            'if [[ "$1" == --suggest-name ]]; then echo "Example Com"; exit 0; fi\n'
            'printf "ARG:%s\\n" "$@"\n'
        )
        common = ["Fixture", "", "", ""]
        cases = [
            ("", ["n", "", "", "y"], {"--chrome-only", "--no-dmg"},
             {"--generate-pwa", "--user-agent", "--chrome-profile-directory"}),
            ("both", ["", "n", "", "", "Profile 1", "", "", "", "y"],
             {"--generate-pwa", "--user-agent", "--chrome-profile-directory", "Profile 1"},
             {"--chrome-only"}),
            ("nativefier", ["", "n", "", "", "", "", "", "y"],
             {"--user-agent", "--no-dmg"},
             {"--chrome-only", "--generate-pwa", "--chrome-profile-directory"}),
        ]
        for mode, tail, expected, excluded in cases:
            with self.subTest(mode=mode or "default"):
                result = self.run_script(
                    "cloning-website-to-dmg.sh",
                    answers="\n".join(["https://example.com/", mode, *common, *tail, ""]),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("suggested name: Example Com", result.stderr)
                args = {line[4:] for line in result.stdout.splitlines() if line.startswith("ARG:")}
                self.assertTrue(expected <= args, args)
                self.assertFalse(excluded & args, args)


if __name__ == "__main__":
    unittest.main()
