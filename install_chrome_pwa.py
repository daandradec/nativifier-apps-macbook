"""Install a real Chrome web app in a fresh, dedicated data directory."""

import fcntl
import hashlib
import json
import os
import plistlib
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit


class InstallError(Exception):
    pass


class ProtocolTimeout(InstallError):
    pass


class ChromePipe:
    def __init__(self, chrome, data_dir):
        # Chrome reads CDP from fd 3 and writes to fd 4. No TCP port is opened.
        self.process = subprocess.Popen(
            ["/bin/bash", "-c", 'exec 3<&0 4>&1 0</dev/null 1>/dev/null; exec "$@"',
             "cdp", str(chrome), f"--user-data-dir={data_dir}", "--remote-debugging-pipe",
             "--enable-devtools-pwa-handler", "--no-first-run", "--no-default-browser-check",
             "--no-startup-window"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.buffer = b""
        self.request_id = 0

    def command(self, method, params=None, session=None, timeout=25):
        self.request_id += 1
        message = {"id": self.request_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        self.process.stdin.write(json.dumps(message).encode() + b"\0")
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\0" not in self.buffer:
                ready, _, _ = select.select([self.process.stdout], [], [],
                                            max(0, deadline - time.monotonic()))
                chunk = os.read(self.process.stdout.fileno(), 65536) if ready else b""
                if not ready:
                    break
                if not chunk:
                    raise InstallError("Chrome cerró la conexión de instalación.")
                self.buffer += chunk
                if len(self.buffer) > 16 * 1024 * 1024:
                    raise InstallError("Chrome devolvió una respuesta demasiado grande.")
                continue
            frame, self.buffer = self.buffer.split(b"\0", 1)
            response = json.loads(frame)
            if response.get("id") != self.request_id:
                continue
            if "error" in response:
                raise InstallError(f"{method}: {response['error']['message']}")
            return response.get("result", {})
        raise ProtocolTimeout(f"Chrome no respondió a {method} a tiempo.")

    def close(self):
        try:
            if self.process.poll() is None:
                try:
                    self.command("Browser.close", timeout=3)
                except (InstallError, OSError):
                    pass
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait()
        finally:
            self.process.stdin.close()
            self.process.stdout.close()


def web_parts(url):
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username is not None:
        raise InstallError("Usa una URL HTTP(S) válida, sin credenciales.")
    return parts


def origin(parts):
    port = parts.port or (443 if parts.scheme == "https" else 80)
    return parts.scheme, parts.hostname, port


def discover_manifest(browser, url):
    requested = web_parts(url)
    browser.command("Browser.getVersion")
    target = browser.command("Target.createTarget", {"url": url, "background": True})["targetId"]
    session = browser.command("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
    browser.command("Page.enable", session=session)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        # A target can attach before its initial navigation commits.
        # A manifest request issued against that document may never answer.
        page = browser.command("Target.getTargetInfo", {"targetId": target})["targetInfo"]["url"]
        if not page.startswith(("http://", "https://")):
            time.sleep(0.4)
            continue
        try:
            manifest = browser.command("Page.getAppManifest", session=session, timeout=3)
        except ProtocolTimeout:
            continue
        if manifest.get("data"):
            manifest_id = browser.command("Page.getAppId", session=session).get("appId")
            if manifest_id:
                page = browser.command("Target.getTargetInfo", {"targetId": target})["targetInfo"]["url"]
                current, identity = web_parts(page), web_parts(manifest_id)
                allowed_origins = {origin(requested)}
                if requested.scheme == "http" and requested.port in (None, 80):
                    allowed_origins.add(("https", requested.hostname, 443))
                if origin(current) not in allowed_origins:
                    raise InstallError(f"El sitio redirigió a otro origen. Usa su URL final: {page}")
                if origin(identity) != origin(current):
                    raise InstallError("El ID del manifiesto no corresponde al origen de la página.")
                return page, manifest_id
        time.sleep(0.4)
    raise InstallError("Chrome no encontró un manifiesto PWA instalable en esa página.")


def chrome_app_id(manifest_id):
    # Chromium double-hashes the canonical manifest ID for backwards compatibility.
    first = hashlib.sha256(manifest_id.encode()).digest()
    return hashlib.sha256(first).hexdigest()[:32].translate(str.maketrans("0123456789abcdef", "abcdefghijklmnop"))


def registered_apps(home, app_id, data_dir=None):
    roots = (home / "Applications", Path("/Applications"))
    for root in roots:
        for folder in (root / "Chrome Apps.localized", root):
            for app in sorted(folder.glob("*.app")):
                if not os.access(app / "Contents/MacOS/app_mode_loader", os.X_OK):
                    continue
                try:
                    with (app / "Contents/Info.plist").open("rb") as info:
                        plist = plistlib.load(info)
                    bundle_id = plist.get("CFBundleIdentifier", "")
                    shim_dir = Path(plist.get("CrAppModeUserDataDir", ""))
                except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
                    continue
                if (plist.get("CrBundleIdentifier") != "com.google.Chrome"
                        or plist.get("CrAppModeShortcutID") != app_id
                        or not bundle_id.startswith("com.google.Chrome.app.")
                        or not bundle_id.endswith(app_id)
                        or not shim_dir.is_absolute() or len(shim_dir.parents) < 3
                        or shim_dir.name != "_crx_" + app_id
                        or shim_dir.parent.name != "Web Applications"
                        or (data_dir is not None and shim_dir.parents[2] != data_dir)):
                    continue
                yield app


def seed_pwa_profile(data_dir, chrome):
    # This is a new, dedicated Chrome profile, not an edit to an existing one.
    # The installer's --no-first-run doesn't create this marker. The macOS
    # web-app shim starts Chrome without that switch the next time it opens.
    (data_dir / "First Run").touch(exist_ok=False)

    profile = data_dir / "Default"
    profile.mkdir()
    with (profile / "Preferences").open("x", encoding="utf-8") as preferences:
        json.dump({"translate": {"enabled": False}}, preferences)

    # The post-onboarding default-browser prompt has a separate,
    # version-scoped preference in this data directory's Local State.
    try:
        with (Path(chrome).parents[1] / "Info.plist").open("rb") as plist:
            version = plistlib.load(plist).get("CFBundleShortVersionString")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return
    if isinstance(version, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version):
        with (data_dir / "Local State").open("x", encoding="utf-8") as state:
            json.dump({"browser": {"suppress_default_browser_prompt_for_version": version}}, state)


def install(chrome, url, home):
    web_parts(url)
    root = home / "Library/Application Support/WebClone/PWA Profiles"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (root / ".install.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise InstallError("Ya hay otra instalación PWA en curso.") from None
        data_dir = Path(tempfile.mkdtemp(prefix="app-", dir=root)).resolve()
        keep_profile = False
        try:
            seed_pwa_profile(data_dir, chrome)
            browser = ChromePipe(chrome, data_dir)
            try:
                page, manifest_id = discover_manifest(browser, url)
                app_id = chrome_app_id(manifest_id)
                existing = list(registered_apps(home, app_id))
                if len(existing) > 1:
                    raise InstallError("Ya existen varias copias de esta app. Abre la correcta desde Chrome.")
                if existing:
                    return existing[0], False
                # If Chrome partially installs the app, keep its profile intact.
                keep_profile = True
                browser.command("PWA.install", {"manifestId": manifest_id, "installUrlOrBundleUrl": page})
                browser.command("PWA.changeAppUserSettings", {"manifestId": manifest_id, "displayMode": "standalone"})
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    matching = list(registered_apps(home, app_id, data_dir))
                    if len(matching) == 1:
                        return matching[0], True
                    time.sleep(0.2)
                raise InstallError("Chrome no creó una .app verificable para la PWA.")
            finally:
                browser.close()
        finally:
            if not keep_profile:
                shutil.rmtree(data_dir)


FINDER_ALIAS_SCRIPT = """
ObjC.import('Foundation');
function run(argv) {
    const target = $.NSURL.fileURLWithPath(argv[0]);
    const alias = $.NSURL.fileURLWithPath(argv[1]);
    const error = Ref();
    const data = target.bookmarkDataWithOptionsIncludingResourceValuesForKeysRelativeToURLError(
        $.NSURLBookmarkCreationSuitableForBookmarkFile, $(), $(), error);
    if (!data || data.isNil() || !$.NSURL.writeBookmarkDataToURLOptionsError(data, alias, 0, error)) {
        throw new Error("No se pudo crear el alias de Finder.");
    }
}
"""


def make_applications_alias(app, folder):
    alias = folder / app.name
    if alias == app:  # Chrome already placed the original directly in this folder.
        return app
    folder.mkdir(exist_ok=True)
    if os.path.lexists(alias):
        raise FileExistsError(str(alias))
    # Publish the real alias (including Finder metadata) without replacing any
    # file that appeared at the destination while the bookmark was generated.
    with tempfile.TemporaryDirectory(prefix=".pwa-alias-", dir=folder) as temporary:
        staged = Path(temporary) / alias.name
        subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-", str(app), str(staged)],
                       input=FINDER_ALIAS_SCRIPT, text=True, check=True, timeout=10,
                       capture_output=True)
        os.link(staged, alias)
    return alias


def place_applications_alias(app, home, system_folder=Path("/Applications")):
    if system_folder.is_dir():
        try:
            return make_applications_alias(app, system_folder)
        except FileExistsError:
            print("[WARN] El nombre ya está ocupado en /Applications. Se usará ~/Applications sin reemplazar nada.",
                  file=sys.stderr)
        except (OSError, subprocess.SubprocessError):
            print("[WARN] No se pudo guardar el alias en /Applications. Se intentará en ~/Applications.",
                  file=sys.stderr)
    return make_applications_alias(app, home / "Applications")


def pin_to_dock(app):
    dockutil = shutil.which("dockutil")
    if not dockutil:
        return False
    found = subprocess.run([dockutil, "--find", str(app)], capture_output=True, timeout=15)
    if found.returncode != 0:
        subprocess.run([dockutil, "--add", str(app)], capture_output=True, check=True, timeout=15)
    return True


def organize_new_pwa(app, home):
    # Alias and Dock are conveniences, not requirements for a working PWA.
    try:
        alias = place_applications_alias(app, home)
        print(f"[INFO] Disponible en Aplicaciones: {alias}")
    except FileExistsError:
        print("[WARN] Ya hay un elemento con ese nombre en ~/Applications; no se reemplazó.",
              file=sys.stderr)
    except (OSError, subprocess.SubprocessError):
        print("[WARN] No se pudo crear el alias. La app original quedó instalada.", file=sys.stderr)

    try:
        if pin_to_dock(app):
            print("[INFO] App disponible en el Dock.")
            return
        print("[WARN] No se encontró dockutil. Instálalo para fijar futuras PWAs automáticamente.",
              file=sys.stderr)
    except (OSError, subprocess.SubprocessError):
        print("[WARN] No se pudo fijar la app en el Dock automáticamente.", file=sys.stderr)
    print("[INFO] Para fijarla ahora: abre la app y elige Opciones → Mantener en el Dock.")


if __name__ == "__main__":
    home = Path.home()
    try:
        app, created = install(sys.argv[1], sys.argv[2], home)
    except (InstallError, OSError, ValueError, KeyError) as error:
        print(f"[ERROR] {error} Si Chrome no admite la instalación automática, usa pwa-manual-guide.",
              file=sys.stderr)
        sys.exit(1)
    print(f"[INFO] {'PWA instalada por Chrome' if created else 'Esta PWA ya está instalada'}: {app}")
    if created:
        print("[INFO] La app usa un perfil separado. No se copiaron sesiones de Chrome ni se generó un DMG.")
        organize_new_pwa(app, home)
