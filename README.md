# Nativefier Apps MacBook

Genera apps de macOS para sitios web con Google Chrome o Nativefier.

## GitHub y otros sitios con «Continuar con Google»

Usa **solo Chrome** para abrir el sitio con el navegador real, sin pasar por
el navegador embebido de Nativefier:

```bash
bash cloning-cli.sh --url https://github.com/ --chrome-only
open "output/GitHub (Chrome)/GitHub.app"
```

El lanzador usa el último perfil de Chrome por defecto. Si alternas entre
cuentas, puedes fijar uno con `--chrome-profile-directory "Profile 1"`.
Chrome debe estar instalado. El lanzador no registra una PWA ni modifica la
configuración del navegador. Pillow es opcional: sin él se conserva el icono
del sitio, sin el distintivo de Chrome.

## Scripts

- `build_inception_chat.sh`: script original orientado a `chat.inceptionlabs.ai`.
- `cloning-cli.sh`: CLI para generar la app y un DMG opcional bajo `./output/`.
- `cloning-website-to-dmg.sh`: asistente interactivo que hace preguntas, arma el comando y ejecuta `cloning-cli.sh`.
- `search-auth-domain`: helper best-effort con Playwright CLI para detectar dominios externos de autenticacion.

## Modos de generación

| Opción del CLI | Apps generadas | Carpeta |
| --- | --- | --- |
| `--chrome-only` | `<AppName>.app` con Google Chrome | `output/<AppName> (Chrome)/` |
| Sin opción de modo | `<AppName>.app` con Nativefier | `output/<AppName>/` |
| `--generate-pwa` | Nativefier y lanzador `<AppName> PWA.app` | `output/<AppName>/` |

`--no-dmg` omite el DMG. `--dmg-output` cambia solo la ruta del DMG principal.
Al reconstruir, se reemplaza la carpeta de salida del modo elegido. **Solo
Chrome** usa una carpeta aparte y no toca las generaciones de Nativefier.
La etiqueta `(Chrome)` solo distingue la carpeta: la app y el DMG usan el
nombre del producto. El DMG contiene la misma app y sirve para copiarla a
Aplicaciones; abrir la app desde la carpeta de salida usa el mismo Chrome.

## Uso interactivo

```bash
bash cloning-website-to-dmg.sh
```

Elige `chrome` (por defecto), `nativefier` o `both` tras indicar la URL.
El asistente muestra el nombre sugerido antes de generar la app. Para
`github.com` es **GitHub**: dejar el nombre vacío produce la misma carpeta que
indicar `--name GitHub`.

## Uso CLI con Nativefier

```bash
bash cloning-cli.sh \
  --url https://app.example.com \
  --name ExampleApp \
  --generate-pwa \
  --internal-domain login.example.com
```

Si no indicas `--internal-urls-regex`, `cloning-cli.sh` intentara detectar dominios de autenticacion automaticamente con `search-auth-domain`. Si ya indicaste `--internal-domain`, el detector buscara alternativas adicionales y las combinara sin duplicados. Si no encuentra nada, el build continua igual.

Si el sitio necesita opciones extra de Nativefier, agregalas despues de `--`.

```bash
bash cloning-cli.sh \
  --url https://app.example.com \
  --name ExampleApp \
  -- --inject ./custom.js
```

## Requisitos

- macOS.
- Para Chrome: Google Chrome y Python 3. No se requiere Node.js.
- Para Nativefier: Node.js y npm (`nativefier` se ejecuta vía `npx`).
- La detección opcional de dominios de autenticación de Nativefier usa el
  wrapper de Playwright CLI y requiere habilitar el ejecutable con
  `chmod +x search-auth-domain`.

## Pruebas

```bash
python3 tests/test_chrome_mode.py
```
