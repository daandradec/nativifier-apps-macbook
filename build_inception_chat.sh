#!/usr/bin/env bash
# ------------------------------------------------------------
# build_inception_chat.sh – genera una app macOS personal de
# chat.inceptionlabs.ai con Nativefier (sin firma, sin notarización)s
# ------------------------------------------------------------

set -euo pipefail   # aborta en errores y variables no definidas

# ---------- CONFIGURACIÓN ----------
APP_NAME="InceptionChat"
APP_URL="https://chat.inceptionlabs.ai"
BUNDLE_ID="com.inceptionlabs.chat"
APP_VERSION="1.0.0"

# Si deseas un ícono propio, pon aquí la ruta a un PNG ≥1024×1024.
# Si lo dejas vacío, Nativefier usará el ícono por defecto de Electron.
ICON_FILE=""                     # <-- p.ej. "./my-icon.png"
AUTO_ICON_FILE="./inceptionchat-icon.png"
AUTO_ICON_DOWNLOADED=false

MENU_FILE="menu.js"
# Cambia a "false" si no quieres crear el DMG
CREATE_DMG=true
# ------------------------------------------------------------

download_icon_if_needed() {
  if [[ -n "${ICON_FILE}" ]]; then
    return
  fi

  echo "🎨 Intentando descargar ícono desde Inception Labs..."
  local icon_candidates=(
    "https://www.inceptionlabs.ai/apple-touch-icon.png"
    "https://www.inceptionlabs.ai/android-chrome-512x512.png"
    "https://www.inceptionlabs.ai/favicon-32x32.png"
    "https://chat.inceptionlabs.ai/apple-touch-icon.png"
    "https://chat.inceptionlabs.ai/android-chrome-512x512.png"
    "https://chat.inceptionlabs.ai/favicon-32x32.png"
  )

  for icon_url in "${icon_candidates[@]}"; do
    if curl -fsSL \
      -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
      "${icon_url}" \
      -o "${AUTO_ICON_FILE}"; then
      if file "${AUTO_ICON_FILE}" | grep -qi "PNG image data"; then
        ICON_FILE="${AUTO_ICON_FILE}"
        AUTO_ICON_DOWNLOADED=true
        echo "✅ Ícono descargado desde: ${icon_url}"
        return
      fi
      rm -f "${AUTO_ICON_FILE}"
    fi
  done

  echo "⚠️ No se pudo descargar ícono desde chat/www.inceptionlabs.ai. Se usará el ícono por defecto."
}

create_unsigned_dmg_with_hdiutil() {
  local dmg_output="$1"
  local dmg_stage
  dmg_stage=$(mktemp -d "./${APP_NAME}-dmg-stage.XXXXXX")
  cp -R "${TARGET_PATH}" "${dmg_stage}/"
  ln -s /Applications "${dmg_stage}/Applications"

  hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${dmg_stage}" \
    -ov \
    -format UDZO \
    "${dmg_output}" >/dev/null

  rm -rf "${dmg_stage}"
}

# 1️⃣ Limpiar caché de Nativefier (si existe)
echo "🧹 Limpiando caché de Nativefier..."
rm -rf "${HOME}/.cache/nativefier" || true

# 1.1️⃣ Limpiar residuos de ejecuciones anteriores (si existen)
echo "🧹 Limpiando carpetas temporales previas..."
rm -rf "./InceptionChat-darwin-arm64" || true
rm -rf ./InceptionChat-dmg-stage.* || true

# 1.5️⃣ Intentar obtener un ícono local para evitar scraping automático (429)
download_icon_if_needed

# 2️⃣ Crear menú macOS (menu.js)
cat > "${MENU_FILE}" <<'EOF'
module.exports = [
  {
    label: "InceptionChat",
    submenu: [
      { role: "about" },
      { type: "separator" },
      { role: "hide" },
      { role: "hideothers" },
      { role: "unhide" },
      { type: "separator" },
      { role: "quit" }
    ]
  },
  {
    label: "Edit",
    submenu: [
      { role: "undo" },
      { role: "redo" },
      { type: "separator" },
      { role: "cut" },
      { role: "copy" },
      { role: "paste" },
      { role: "selectAll" }
    ]
  },
  {
    label: "View",
    submenu: [
      { role: "reload" },
      { role: "forcereload" },
      { role: "toggledevtools" },
      { type: "separator" },
      { role: "resetzoom" },
      { role: "zoomin" },
      { role: "zoomout" },
      { type: "separator" },
      { role: "togglefullscreen" }
    ]
  }
];
EOF

# 3️⃣ Construir la aplicación con Nativefier
echo "🚀 Generando la aplicación con Nativefier..."
NATIVEFIER_CMD=(
  npx nativefier "${APP_URL}"
  --name "${APP_NAME}"
  --app-bundle-id "${BUNDLE_ID}"
  --app-version "${APP_VERSION}"
  --user-agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  --darwin-dark-mode-support
  --single-instance
  --menu "${MENU_FILE}"
  --platform mac
  --overwrite
)

# Añadimos --icon solo si el archivo existe y es válido
if [[ -n "${ICON_FILE}" && -f "${ICON_FILE}" ]]; then
  NATIVEFIER_CMD+=(--icon "${ICON_FILE}")
fi

# Ejecutamos el comando
"${NATIVEFIER_CMD[@]}"

# 4️⃣ Detectar la carpeta de salida (funciona tanto para x64 como para arm64)
OUTPUT_DIR=$(ls -d ${APP_NAME}-darwin* 2>/dev/null | head -n1 || true)

if [[ -z "${OUTPUT_DIR}" ]]; then
  echo "❌ No se encontró la carpeta de salida de Nativefier. Abortando."
  exit 1
fi

echo "📦 Carpeta de salida detectada: ${OUTPUT_DIR}"

# 5️⃣ Mover la app a /Applications (puedes cambiar la ruta si lo prefieres)
TARGET_PATH="/Applications/${APP_NAME}.app"
echo "🚚 Moviendo la app a ${TARGET_PATH}..."
if [[ -e "${TARGET_PATH}" ]]; then
  echo "♻️ Eliminando versión anterior en ${TARGET_PATH}..."
  rm -rf "${TARGET_PATH}"
fi
mv "${OUTPUT_DIR}/${APP_NAME}.app" "${TARGET_PATH}"

# 6️⃣ (Opcional) Crear DMG para distribución o simplemente para tener un instalador fácil
if $CREATE_DMG; then
  echo "🗂️ Creando DMG..."
  DMG_PATH="./${APP_NAME} ${APP_VERSION}.dmg"
  CREATE_DMG_WORKED=false

  # Intento 1: create-dmg sin firma (si está disponible)
  if command -v create-dmg >/dev/null 2>&1; then
    CREATE_DMG_HELP="$(create-dmg --help 2>&1 || true)"
    CREATE_DMG_NO_SIGN_FLAG=()
    if echo "${CREATE_DMG_HELP}" | grep -Fq -- "--no-code-sign"; then
      CREATE_DMG_NO_SIGN_FLAG+=(--no-code-sign)
    fi

    if echo "${CREATE_DMG_HELP}" | grep -Fq "<app> [destination]"; then
      # Variante npm (sindresorhus/create-dmg): create-dmg <app> [destination]
      if create-dmg "${TARGET_PATH}" "." --overwrite "${CREATE_DMG_NO_SIGN_FLAG[@]}"; then
        FOUND_DMG="$(ls -1t ./*.dmg 2>/dev/null | grep -E "/${APP_NAME}.*\\.dmg$" | head -n1 || true)"
        if [[ -n "${FOUND_DMG}" && -f "${FOUND_DMG}" ]]; then
          DMG_PATH="${FOUND_DMG}"
          CREATE_DMG_WORKED=true
        fi
      fi
    elif echo "${CREATE_DMG_HELP}" | grep -Fq "<output.dmg> <source_folder>"; then
      # Variante create-dmg clásica
      DMG_STAGING_DIR=$(mktemp -d "./${APP_NAME}-dmg-stage.XXXXXX")
      cp -R "${TARGET_PATH}" "${DMG_STAGING_DIR}/"
      ln -s /Applications "${DMG_STAGING_DIR}/Applications"

      CREATE_DMG_CMD=(
        create-dmg
        "${DMG_PATH}"
        "${DMG_STAGING_DIR}"
        --overwrite
        --icon "${APP_NAME}.app" 180 170
        --icon "Applications" 460 170
        --window-size 640 420
        --icon-size 128
      )
      if [[ -f "./dmg-bg.png" ]]; then
        CREATE_DMG_CMD+=(--background "./dmg-bg.png")
      fi
      CREATE_DMG_CMD+=("${CREATE_DMG_NO_SIGN_FLAG[@]}")

      if "${CREATE_DMG_CMD[@]}"; then
        CREATE_DMG_WORKED=true
      fi
      rm -rf "${DMG_STAGING_DIR}"
    fi
  fi

  # Intento 2 (fallback): hdiutil sin firma para uso local
  if ! $CREATE_DMG_WORKED; then
    echo "⚠️ create-dmg falló o requiere firma. Creando DMG sin firma con hdiutil..."
    create_unsigned_dmg_with_hdiutil "${DMG_PATH}"
  fi

  if [[ -n "${DMG_PATH}" && -f "${DMG_PATH}" ]]; then
    echo "✅ DMG sin firma creado: ${DMG_PATH}"
  else
    echo "❌ create-dmg terminó pero no se encontró el archivo .dmg generado."
    exit 1
  fi
fi

# 7️⃣ Limpieza de archivos temporales (menú y posible ícono)
echo "🧽 Limpiando archivos temporales..."
rm -f "${MENU_FILE}"
if $AUTO_ICON_DOWNLOADED && [[ -f "${AUTO_ICON_FILE}" ]]; then
  rm -f "${AUTO_ICON_FILE}"
fi
[[ -d "${OUTPUT_DIR}" ]] && rm -rf "${OUTPUT_DIR}"

echo "🎉 ¡Proceso completado! La aplicación está en ${TARGET_PATH}"
