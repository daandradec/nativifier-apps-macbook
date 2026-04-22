# Nativefier Apps MacBook

Coleccion de scripts para generar apps nativas de macOS usando Nativefier.

## Scripts

- `build_inception_chat.sh`: script original orientado a `chat.inceptionlabs.ai`.
- `cloning-cli.sh`: CLI generica para cualquier sitio web. Guarda la app en `./output/<AppName>/` y crea un DMG opcional.
- `cloning-website-to-dmg.sh`: asistente interactivo que hace preguntas, arma el comando y ejecuta `cloning-cli.sh`.
- `search-auth-domain`: helper best-effort con Playwright CLI para detectar dominios externos de autenticacion.

## Salidas por defecto

- App: `./output/<AppName>/<AppName>.app`
- DMG: `./output/<AppName>/<AppName> <version>.dmg`
- PWA app: `./output/<AppName>/<AppName> PWA.app`
- PWA DMG: `./output/<AppName>/<AppName> PWA <version>.dmg`

`--dmg-output` solo cambia la ruta del DMG. La app siempre queda bajo `./output/<AppName>/`.
Si usas `--generate-pwa`, tambien se crea un lanzador tipo PWA basado en Google Chrome para reutilizar la sesion actual del navegador.
Si ejecutas de nuevo el script con el mismo `AppName`, la carpeta `./output/<AppName>/` se elimina primero para evitar archivos viejos mezclados con la nueva generacion.

## Uso interactivo

```bash
chmod +x cloning-website-to-dmg.sh cloning-cli.sh search-auth-domain
./cloning-website-to-dmg.sh
```

## Uso CLI

```bash
./cloning-cli.sh \
  --url https://app.example.com \
  --name ExampleApp \
  --generate-pwa \
  --internal-domain login.example.com
```

Si no indicas `--internal-urls-regex`, `cloning-cli.sh` intentara detectar dominios de autenticacion automaticamente con `search-auth-domain`. Si ya indicaste `--internal-domain`, el detector buscara alternativas adicionales y las combinara sin duplicados. Si no encuentra nada, el build continua igual.

Si el sitio necesita opciones extra de Nativefier, agregalas despues de `--`.

```bash
./cloning-cli.sh \
  --url https://app.example.com \
  --name ExampleApp \
  -- --inject ./custom.js
```

## Requisitos

- macOS
- Node.js + npm
- `nativefier` via `npx`
- Playwright CLI wrapper disponible en `~/.codex/skills/playwright/scripts/playwright_cli.sh` para la auto-deteccion de autenticacion
