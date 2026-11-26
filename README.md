# Nativefier Apps MacBook

Genera apps de macOS para sitios web con Google Chrome o Nativefier.

## GitHub y otros sitios con «Continuar con Google»

Para registrar la PWA real con Chrome sin pasar por el menú:

```bash
bash cloning-cli.sh --url https://github.com/ --pwa
```

Chrome crea la `.app` local usando el manifiesto del sitio y un perfil
separado; no reutiliza las cookies ni las sesiones de tu perfil habitual.
En el perfil nuevo, Chrome no ofrece ni inicia traducciones automáticamente.
El script omite la bienvenida de Chrome y su aviso de navegador predeterminado
para la versión usada al instalar, sin cambiar el navegador predeterminado de
macOS.
El CLI muestra la ruta que creó Chrome. Si ya hay una copia de la misma
PWA, muestra su ubicación sin reinstalar ni cambiar sus preferencias.
Esta instalación depende de una
[API experimental de Chrome](https://chromedevtools.github.io/devtools-protocol/tot/PWA/#method-install).
El acceso queda ligado al perfil de la Mac: no se empaqueta como DMG portátil.

En una instalación nueva, el script deja la `.app` original donde la creó
Chrome y coloca un alias en **Macintosh HD → Aplicaciones** (`/Applications`).
Si no puede escribir ahí o ese nombre está ocupado, usa la carpeta personal
**`~/Applications`** sin reemplazar ningún archivo ni pedir permisos de
administrador. Si tienes [`dockutil`](https://github.com/kcrawford/dockutil)
en tu `PATH`, también fija la app original en el Dock. Por ejemplo, si ya
usas Homebrew puedes instalarlo con `brew install dockutil`. Si no está
disponible, abre la app y elige **Opciones → Mantener en el Dock**.
Las PWAs que ya estaban instaladas no se modifican.

Para usar tu perfil habitual, o si Chrome no reconoce un manifiesto que
pueda instalar automáticamente, elige **`pwa-manual-guide`**:

```bash
bash cloning-cli.sh --url https://github.com/ --pwa-manual-guide
```

En Chrome, ve a **⋮ → Enviar, guardar y compartir → Instalar página como
aplicación** y confirma. El modo guiado no crea archivos por sí solo.
El flag anterior `--install-pwa` sigue siendo un alias de esta guía.

Si ya la instalaste, ábrela desde el Dock o `chrome://apps`. No necesitas
volver a ejecutar el asistente.

## Scripts

- `build_inception_chat.sh`: script original orientado a `chat.inceptionlabs.ai`.
- `cloning-cli.sh`: CLI para generar la app y un DMG opcional bajo `./output/`.
- `cloning-website-to-dmg.sh`: asistente interactivo que hace preguntas, arma el comando y ejecuta `cloning-cli.sh`.
- `search-auth-domain`: helper best-effort con Playwright CLI para detectar dominios externos de autenticacion.

## Modos de generación

| Opción del CLI | Apps generadas | Carpeta |
| --- | --- | --- |
| `--pwa` | PWA real: Chrome registra una `.app` | Carpeta de apps de Chrome |
| `--chrome-window-simple` | Acceso en ventana con Chrome `--app`, no registra la PWA; DMG opcional | `output/<AppName> (Chrome Window Simple)/` |
| `--pwa-manual-guide` | Guía para instalar la app web desde Chrome | Sin archivos generados por el CLI |
| Sin opción de modo | `<AppName>.app` con Nativefier y DMG opcional | `output/<AppName>/` |

`--no-dmg` omite el DMG. `--dmg-output` cambia solo la ruta del DMG principal.
Al reconstruir con Nativefier o Chrome Window Simple, se reemplaza la carpeta de salida
de esa app en el modo elegido.
El DMG permite copiar la app generada a Aplicaciones.

## Uso interactivo

```bash
bash cloning-website-to-dmg.sh
```

En la pregunta 2, pulsa Enter para usar **`nativefier`** (predeterminado)
o elige **`pwa`**, **`chrome-window-simple`** o **`pwa-manual-guide`**.
En el modo guiado puedes indicar el perfil de Chrome (por ejemplo, `Profile 1`).
El asistente muestra el nombre sugerido antes de empaquetar la app. Para
`github.com` es **GitHub**: dejar el nombre vacío produce la misma carpeta que
indicar `--name GitHub`.

## Uso CLI con Nativefier

```bash
bash cloning-cli.sh \
  --url https://app.example.com \
  --name ExampleApp \
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
- Para PWA y Chrome Window Simple: Google Chrome y Python 3; no requieren Node.js.
- Para PWA Manual Guide: Google Chrome. El asistente usa Python 3, si está
  disponible, para sugerir perfiles.
- Para Nativefier: Node.js y npm (`nativefier` se ejecuta vía `npx`).
- La detección opcional de dominios de autenticación de Nativefier usa el
  wrapper de Playwright CLI y requiere habilitar el ejecutable con
  `chmod +x search-auth-domain`.

## Pruebas

```bash
python3 -m unittest discover -s tests
```
