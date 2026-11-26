import json
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
from unittest.mock import call, patch

import install_chrome_pwa


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


class PWAInstallerTests(unittest.TestCase):
    URL = "https://example.invalid/"

    def test_chromium_manifest_hash_matches_real_github_shim(self):
        self.assertEqual(install_chrome_pwa.chrome_app_id("https://github.com/"),
                         "mjoklplbddabcmpepnokjaffbmgbkkgg")

    def run_install(self, home, installed):
        app = home / "Apps/Fixture.app"
        chrome = home / "Chrome.app/Contents/MacOS/Google Chrome"
        chrome.parent.mkdir(parents=True)
        version = "158.0.8127.37"
        (chrome.parents[1] / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleShortVersionString": version}))

        def check_initial_preferences(_chrome, directory):
            preferences = json.loads((directory / "Default/Preferences").read_text())
            self.assertIs(preferences["translate"]["enabled"], False)
            self.assertTrue((directory / "First Run").is_file())
            state = json.loads((directory / "Local State").read_text())
            self.assertEqual(state["browser"]["suppress_default_browser_prompt_for_version"], version)
            return pipe.return_value

        with patch.object(install_chrome_pwa, "ChromePipe") as pipe, \
                patch.object(install_chrome_pwa, "discover_manifest",
                             return_value=(self.URL, self.URL)), \
                patch.object(install_chrome_pwa, "registered_apps",
                             side_effect=[[app]] if installed else [[], [app]]):
            pipe.side_effect = check_initial_preferences
            result = install_chrome_pwa.install(str(chrome), self.URL, home)
            profile = pipe.call_args.args[1]
            commands = [entry.args[0] for entry in pipe.return_value.command.call_args_list]
            pipe.return_value.close.assert_called_once_with()
        self.assertEqual(result, (app, not installed))
        self.assertEqual(profile.is_dir(), not installed)
        self.assertEqual(commands, [] if installed else ["PWA.install", "PWA.changeAppUserSettings"])

    def test_install_keeps_isolated_profile_for_chrome_bundle(self):
        with tempfile.TemporaryDirectory() as root:
            self.run_install(Path(root), installed=False)

    def test_existing_registration_is_reused_without_installing_again(self):
        with tempfile.TemporaryDirectory() as root:
            self.run_install(Path(root), installed=True)

    def test_unknown_chrome_version_still_skips_first_run(self):
        with tempfile.TemporaryDirectory() as root:
            profile = Path(root)
            chrome = profile / "Chrome.app/Contents/MacOS/Google Chrome"
            install_chrome_pwa.seed_pwa_profile(profile, chrome)
            self.assertTrue((profile / "First Run").is_file())
            self.assertFalse((profile / "Local State").exists())


class PWAShortcutTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "uses macOS Foundation aliases")
    def test_applications_alias_resolves_to_original_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            original = home / "Applications/Chrome Apps.localized/Fixture.app"
            original.mkdir(parents=True)
            system_folder = home / "System Applications"
            system_folder.mkdir()
            alias = install_chrome_pwa.place_applications_alias(original, home, system_folder)
            self.assertEqual(alias, system_folder / "Fixture.app")
            resolver = """
                ObjC.import('Foundation');
                function run(argv) {
                    const alias = $.NSURL.fileURLWithPath(argv[0]);
                    return ObjC.unwrap($.NSURL.URLByResolvingAliasFileAtURLOptionsError(
                        alias, $.NSURLBookmarkResolutionWithoutUI, Ref()).path);
                }
            """
            result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-", str(alias)],
                                    input=resolver, check=True, text=True, capture_output=True)
            self.assertEqual(Path(result.stdout.strip()).resolve(), original.resolve())
            with self.assertRaises(FileExistsError):
                install_chrome_pwa.make_applications_alias(original, system_folder)
            self.assertTrue(original.is_dir())

    def test_unwritable_or_occupied_system_location_falls_back_to_user_folder(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            system_folder = home / "System Applications"
            system_folder.mkdir()
            app = home / "Chrome Apps/Fixture.app"
            fallback = home / "Applications/Fixture.app"
            for failure in (PermissionError("denied"), FileExistsError("occupied")):
                with self.subTest(failure=failure), \
                        patch.object(install_chrome_pwa, "make_applications_alias",
                                     side_effect=[failure, fallback]) as create, \
                        patch("sys.stderr"):
                    self.assertEqual(install_chrome_pwa.place_applications_alias(
                        app, home, system_folder), fallback)
                    self.assertEqual(create.call_args_list, [
                        call(app, system_folder),
                        call(app, home / "Applications"),
                    ])

    def test_dock_pins_original_once_when_tool_is_available(self):
        app = Path("/fixture/Chrome Apps.localized/Fixture.app")
        tool = "/fixture/dockutil"
        with patch.object(install_chrome_pwa.shutil, "which", return_value=tool), \
                patch.object(install_chrome_pwa.subprocess, "run") as run:
            run.return_value.returncode = 1
            self.assertTrue(install_chrome_pwa.pin_to_dock(app))
            self.assertEqual(run.call_args_list, [
                call([tool, "--find", str(app)], capture_output=True, timeout=15),
                call([tool, "--add", str(app)], capture_output=True, check=True, timeout=15),
            ])
            run.reset_mock()
            run.return_value.returncode = 0
            self.assertTrue(install_chrome_pwa.pin_to_dock(app))
            run.assert_called_once_with([tool, "--find", str(app)], capture_output=True, timeout=15)

    def test_missing_dockutil_leaves_dock_alone(self):
        with patch.object(install_chrome_pwa.shutil, "which", return_value=None), \
                patch.object(install_chrome_pwa.subprocess, "run") as run:
            self.assertFalse(install_chrome_pwa.pin_to_dock(Path("/fixture/Fixture.app")))
            run.assert_not_called()


class AppModeTests(unittest.TestCase):
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

    @unittest.skipUnless(sys.platform == "darwin", "uses macOS DMG tools")
    def test_nativefier_builds_app_and_optional_dmg(self):
        shutil.copyfile(ROOT / "cloning-cli.sh", self.work / "cloning-cli.sh")
        icon = self.work / "icon.png"
        make_png(icon)
        for tool, script in {
            "node": "exit 0",
            "npx": 'mkdir -p "Fixture-darwin-arm64/Fixture.app/Contents"',
        }.items():
            executable = self.bin / tool
            executable.write_text(f"#!/bin/sh\n{script}\n")
            executable.chmod(0o755)

        output = self.work / "output/Fixture"
        for create_dmg in (False, True):
            with self.subTest(create_dmg=create_dmg):
                result = self.run_script(
                    "cloning-cli.sh", "--url", "https://example.com/", "--name", "Fixture",
                    "--icon", str(icon), *([] if create_dmg else ["--no-dmg"]),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                expected = ["Fixture.app"]
                if create_dmg:
                    expected.append("Fixture 1.0.0.dmg")
                self.assertEqual(sorted(p.name for p in output.iterdir()), sorted(expected))
                self.assertTrue((output / "Fixture.app/Contents").is_dir())

    def test_retired_mode_flags_are_rejected_without_building(self):
        shutil.copyfile(ROOT / "cloning-cli.sh", self.work / "cloning-cli.sh")
        for flag in ("--chrome-only", "--generate-pwa", "--pwa-basic"):
            with self.subTest(flag=flag):
                result = self.run_script("cloning-cli.sh", "--url", "https://github.com/", flag)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Argumento no reconocido: {flag}", result.stderr)
        help_result = self.run_script("cloning-cli.sh", "--help")
        self.assertEqual(help_result.returncode, 0)
        for mode in ("--pwa", "--chrome-window-simple", "--pwa-manual-guide"):
            self.assertIn(mode, help_result.stdout)
        self.assertNotIn("--chrome-only", help_result.stdout)
        self.assertNotIn("--generate-pwa", help_result.stdout)
        self.assertNotIn("--pwa-basic", help_result.stdout)
        self.assertFalse((self.work / "output").exists())

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

    @unittest.skipUnless(sys.platform == "darwin", "uses the macOS Chrome launcher")
    def test_manual_guide_opens_chrome_without_building(self):
        self.prepare_cli()
        cli = self.work / "cloning-cli.sh"
        fake_open = self.bin / "open-probe"
        fake_open.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n')
        fake_open.chmod(0o755)
        cli.write_text(cli.read_text()
                       .replace('"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"',
                                '"/missing/Google Chrome.app/Contents/MacOS/Google Chrome"')
                       .replace("/usr/bin/open -", f"{shlex.quote(str(fake_open))} -"))
        chrome = str(self.home / "Applications/Google Chrome.app")
        profile = self.home / "Library/Application Support/Google/Chrome/Profile 1"
        profile.mkdir(parents=True)
        output = self.work / "output/playwright"
        output.mkdir(parents=True)
        url = "https://github.com/"
        cases = [
            ([], ["-a", chrome, url]),
            (["--chrome-profile-directory", "Profile 1"],
             ["-n", "-a", chrome, "--args", "--profile-directory=Profile 1", url]),
        ]
        for extra, expected in cases:
            result = self.run_script("cloning-cli.sh", "--url", url, "--pwa-manual-guide", *extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Instalar página como aplicación", result.stdout)
            args = [line for line in result.stdout.splitlines() if not line.startswith("[INFO]")]
            self.assertEqual(args, expected)
        result = self.run_script(
            "cloning-cli.sh", "--url", url, "--pwa-manual-guide",
            "--chrome-profile-directory", "Profile 9",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(list(output.parent.iterdir()), [output])

    @unittest.skipUnless(sys.platform == "darwin", "uses macOS Chrome and DMG tools")
    def test_chrome_window_simple_builds_url_launcher_not_registered_pwa(self):
        self.prepare_cli()
        icon = self.work / "icon.png"
        make_png(icon)
        url = "https://example.com/?a=1&b=2"
        result = self.run_script("cloning-cli.sh", "--url", url, "--chrome-window-simple", "--name", "Fixture",
                                 "--icon", str(icon))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = self.work / "output/Fixture (Chrome Window Simple)"
        self.assertTrue((output / "Fixture 1.0.0.dmg").is_file())
        bundle = output / "Fixture.app/Contents"
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.local.webclone.fixture.pwa-basic")
        launcher = bundle / "MacOS" / info["CFBundleExecutable"]
        self.assertTrue(os.access(launcher, os.X_OK))
        probe = self.work / "probe.sh"
        probe.write_text(launcher.read_text().replace("exec /usr/bin/open", 'printf "%s\\n"'))
        result = self.run_script("probe.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["-g", "-n", "-b", "com.google.Chrome", "--args", f"--app={url}"])

    @unittest.skipUnless(sys.platform == "darwin", "uses the macOS Chrome discovery")
    def test_pwa_routes_to_real_installer_not_the_guide(self):
        self.prepare_cli()
        (self.work / "install_chrome_pwa.py").write_text('import sys; print(sys.argv[-1])\n')
        url = "https://example.com/"
        result = self.run_script("cloning-cli.sh", "--pwa", "--url", url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], url)
        self.assertNotIn("Instalar página como aplicación", result.stdout)
        self.assertFalse((self.work / "output").exists())
        result = self.run_script("cloning-cli.sh", "--pwa", "--chrome-window-simple", "--url", url)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Elige un solo modo", result.stderr)

    def test_wizard_mode_routes(self):
        shutil.copyfile(ROOT / "cloning-website-to-dmg.sh", self.work / "cloning-website-to-dmg.sh")
        (self.work / "cloning-cli.sh").write_text(
            'if [[ "$1" == --suggest-name ]]; then echo "Example Com"; exit 0; fi\n'
            'printf "ARG:%s\\n" "$@"\n'
        )
        common = ["Fixture", "", "", ""]
        nativefier_tail = ["", "n", "", "", "", "", "", "y"]
        nativefier_flags = {"--user-agent", "--no-dmg"}
        pwa_flags = {"--pwa", "--chrome-window-simple", "--pwa-manual-guide", "--chrome-profile-directory"}
        retired_flags = {"--chrome-only", "--generate-pwa", "--pwa-basic"}
        cases = [
            ([""], nativefier_tail, nativefier_flags, pwa_flags),
            (["nativefier"], nativefier_tail, nativefier_flags, pwa_flags),
            (["pwa"], ["y"], {"--pwa"}, nativefier_flags | {"--chrome-profile-directory"}),
            (["chrome-window-simple"], ["n", "", "y"], {"--chrome-window-simple", "--no-dmg"},
             pwa_flags - {"--chrome-window-simple"} | {"--user-agent"}),
            (["pwa-manual-guide"], ["Profile 1", "y"],
             {"--pwa-manual-guide", "--chrome-profile-directory", "Profile 1"},
             {"--no-dmg", "--dmg-output", "--name", "--version", "--user-agent"}),
            (["chrome", "pwa-manual-guide"], ["Profile 1", "y"],
             {"--pwa-manual-guide", "--chrome-profile-directory", "Profile 1"},
             nativefier_flags),
        ]
        for answers, tail, expected, excluded in cases:
            with self.subTest(answers=answers):
                packages_app = answers[-1] in ("", "nativefier", "chrome-window-simple")
                result = self.run_script(
                    "cloning-website-to-dmg.sh",
                    answers="\n".join(["https://example.com/", *answers,
                                       *(common if packages_app else []), *tail, ""]),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Build mode: nativefier / pwa / chrome-window-simple / pwa-manual-guide [nativefier]",
                              result.stderr)
                self.assertEqual("Choose nativefier, pwa, chrome-window-simple, or pwa-manual-guide." in result.stderr,
                                 "chrome" in answers)
                self.assertEqual("suggested name: Example Com" in result.stderr, packages_app)
                self.assertEqual("Create a DMG installer?" in result.stderr, packages_app)
                self.assertEqual("Chrome profile directory (optional)" in result.stderr,
                                 answers[-1] == "pwa-manual-guide")
                args = {line[4:] for line in result.stdout.splitlines() if line.startswith("ARG:")}
                self.assertTrue(expected <= args, args)
                self.assertFalse((excluded | retired_flags) & args, args)


if __name__ == "__main__":
    unittest.main()
