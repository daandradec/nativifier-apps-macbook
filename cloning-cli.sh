#!/usr/bin/env bash
# ------------------------------------------------------------
# cloning-cli.sh
# Genera una app macOS con Nativefier para cualquier sitio web,
# guarda la app en output/<AppName>/ y crea un DMG opcional.
# ------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
AUTH_DETECTOR="${SCRIPT_DIR}/search-auth-domain"

APP_URL=""
APP_NAME=""
APP_SLUG=""
BUNDLE_ID=""
APP_VERSION="1.0.0"
ICON_FILE=""
USER_AGENT="${DEFAULT_USER_AGENT}"
CREATE_DMG=true
GENERATE_PWA=false
KEEP_BUILD_ARTIFACTS=false
CLEAR_NATIVEFIER_CACHE=true
DMG_OUTPUT=""
RAW_INTERNAL_URLS_REGEX=""
PWA_CHROME_PROFILE_DIRECTORY=""
OUTPUT_ROOT_DIR="${SCRIPT_DIR}/output"
OUTPUT_DIR=""
DEPRECATED_INSTALL_FLAG_USED=false
KNOWN_EMBEDDED_LOGIN_LIMITS=false
PWA_APP_NAME=""
PWA_APP_PATH=""
PWA_DMG_OUTPUT=""
PWA_ICON_ICNS=""

declare -a EXTRA_INTERNAL_DOMAINS=()
declare -a EXTRA_NATIVEFIER_ARGS=()

SESSION_DIR=""
MENU_FILE=""
AUTO_ICON_FILE=""
AUTO_ICON_DOWNLOADED=false
BUILD_OUTPUT_DIR=""
TARGET_PATH=""

usage() {
  cat <<'EOF'
Uso:
  ./cloning-cli.sh --url URL [opciones] [-- nativefier_args...]

Opciones:
  --url URL                     URL del sitio a empaquetar. Requerido.
  --name NAME                   Nombre de la app. Si se omite, se deriva del dominio.
  --bundle-id ID                Bundle ID de macOS. Default: com.local.webclone.<slug>
  --version VERSION             Version de la app/DMG. Default: 1.0.0
  --icon PATH                   Ruta a un icono local PNG/JPG/JPEG.
  --dmg-output PATH             Ruta del DMG final. Solo afecta al DMG.
  --internal-domain HOST        Dominio adicional que debe abrirse dentro de la app.
                                Repetible. Util para SSO/OAuth.
  --internal-urls-regex REGEX   Regex completa para Nativefier --internal-urls.
  --user-agent STRING           User-Agent custom para iconos y Nativefier.
  --no-dmg                      No crear DMG.
  --generate-pwa                Genera tambien una app tipo PWA basada en Google Chrome.
  --chrome-profile-directory X  Perfil de Chrome para la PWA. Ej: Default, Profile 1.
                                Si se omite, la PWA detecta el ultimo perfil usado.
  --keep-build-artifacts        Conserva archivos temporales de compilacion.
  --keep-nativefier-cache       No borra la cache de Nativefier antes de compilar.
  --install-dir PATH            Opcion deprecada; ahora se ignora.
  --no-install                  Opcion deprecada; ahora se ignora.
  -h, --help                    Muestra esta ayuda.

Salidas:
  - App: ./output/<AppName>/<AppName>.app
  - DMG: ./output/<AppName>/<AppName> <version>.dmg
  - PWA app: ./output/<AppName>/<AppName> PWA.app
  - PWA DMG: ./output/<AppName>/<AppName> PWA <version>.dmg
  - --dmg-output solo cambia la ruta del DMG, no la carpeta de la app.

Notas:
  - Todo lo que venga despues de -- se pasa directo a Nativefier.
  - Si no defines --internal-domain ni --internal-urls-regex, el script
    intentara detectar dominios de autenticacion automaticamente con
    search-auth-domain. Si no encuentra nada, continua normalmente.

Ejemplos:
  ./cloning-cli.sh \
    --url https://chat.openai.com \
    --name ChatGPTDesktop

  ./cloning-cli.sh \
    --url https://app.example.com \
    --name ExampleApp \
    --generate-pwa \
    --internal-domain login.example.com \
    -- --inject ./custom.js
EOF
}

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ "${KEEP_BUILD_ARTIFACTS}" == true ]]; then
    return 0
  fi

  [[ -n "${SESSION_DIR}" && -d "${SESSION_DIR}" ]] && rm -rf "${SESSION_DIR}"
  [[ -d "${OUTPUT_ROOT_DIR}/playwright" ]] && rmdir "${OUTPUT_ROOT_DIR}/playwright" >/dev/null 2>&1 || true
  [[ -d "${OUTPUT_ROOT_DIR}" ]] && rmdir "${OUTPUT_ROOT_DIR}" >/dev/null 2>&1 || true
  return 0
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "No se encontro el comando requerido: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

sanitize_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

derive_app_name_from_url() {
  local url="$1"
  local host

  host="$(extract_host "${url}")"
  host="${host#www.}"

  printf '%s' "${host}" \
    | tr '.-_' '   ' \
    | awk '{
        for (i = 1; i <= NF; i++) {
          $i = toupper(substr($i, 1, 1)) tolower(substr($i, 2))
        }
        print
      }'
}

extract_scheme() {
  local url="$1"
  printf '%s\n' "${url%%://*}"
}

extract_host() {
  local url="$1"
  local without_scheme="${url#*://}"
  without_scheme="${without_scheme%%/*}"
  without_scheme="${without_scheme%%\?*}"
  without_scheme="${without_scheme%%#*}"
  without_scheme="${without_scheme%%:*}"
  printf '%s\n' "${without_scheme}"
}

is_google_embedded_login_target() {
  local host
  host="$(extract_host "$1" | tr '[:upper:]' '[:lower:]')"

  case "${host}" in
    gemini.google.com|accounts.google.com|*.google.com|*.googleusercontent.com)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

extract_origin() {
  local url="$1"
  local scheme host
  scheme="$(extract_scheme "${url}")"
  host="$(extract_host "${url}")"
  printf '%s://%s\n' "${scheme}" "${host}"
}

extract_base_dir() {
  local url="$1"
  local stripped="${url%%\#*}"
  local scheme host remainder directory

  stripped="${stripped%%\?*}"
  scheme="$(extract_scheme "${stripped}")"
  host="$(extract_host "${stripped}")"
  remainder="${stripped#*://}"
  remainder="${remainder#${host}}"

  if [[ -z "${remainder}" || "${remainder}" == "/" ]]; then
    printf '%s://%s/\n' "${scheme}" "${host}"
    return
  fi

  directory="${remainder%/*}"
  if [[ -z "${directory}" ]]; then
    printf '%s://%s/\n' "${scheme}" "${host}"
    return
  fi

  printf '%s://%s%s/\n' "${scheme}" "${host}" "${directory}"
}

escape_regex() {
  printf '%s' "$1" | sed -E 's/[][(){}.^$+*?|\\]/\\&/g'
}

resolve_url() {
  local base_url="$1"
  local candidate="$2"
  local scheme origin base_dir

  [[ -z "${candidate}" ]] && return 1

  case "${candidate}" in
    http://*|https://*)
      printf '%s\n' "${candidate}"
      ;;
    //*)
      scheme="$(extract_scheme "${base_url}")"
      printf '%s:%s\n' "${scheme}" "${candidate}"
      ;;
    /*)
      origin="$(extract_origin "${base_url}")"
      printf '%s%s\n' "${origin}" "${candidate}"
      ;;
    *)
      base_dir="$(extract_base_dir "${base_url}")"
      printf '%s%s\n' "${base_dir}" "${candidate}"
      ;;
  esac
}

default_dmg_filename() {
  printf '%s %s.dmg' "${APP_NAME}" "${APP_VERSION}"
}

default_pwa_dmg_filename() {
  printf '%s PWA %s.dmg' "${APP_NAME}" "${APP_VERSION}"
}

append_unique_domain() {
  local candidate="$1"
  local existing

  candidate="$(trim "${candidate}")"
  [[ -n "${candidate}" ]] || return 0

  for existing in "${EXTRA_INTERNAL_DOMAINS[@]}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done

  EXTRA_INTERNAL_DOMAINS+=("${candidate}")
}

build_internal_urls_regex() {
  local domains=()
  local host escaped joined=""

  host="$(extract_host "${APP_URL}")"
  domains+=("${host}")
  domains+=("${EXTRA_INTERNAL_DOMAINS[@]}")

  for host in "${domains[@]}"; do
    [[ -z "${host}" ]] && continue
    escaped="$(escape_regex "${host}")"
    if [[ -n "${joined}" ]]; then
      joined+="|"
    fi
    joined+="([^/]+\\.)?${escaped}"
  done

  printf 'https?://(%s)([/:?#].*)?$' "${joined}"
}

discover_icon_candidates_from_html() {
  local url="$1"
  local html

  html="$(curl -fsSL --max-time 20 -A "${USER_AGENT}" "${url}" 2>/dev/null || true)"
  [[ -z "${html}" ]] && return 1

  printf '%s' "${html}" | perl -0ne '
    my %seen;
    my $index = 0;
    while (/<link\b[^>]*rel=["'"'"']([^"'"'"']*(?:apple-touch-icon|icon|shortcut icon)[^"'"'"']*)["'"'"'][^>]*href=["'"'"']([^"'"'"']+)["'"'"'][^>]*?(?:type=["'"'"']([^"'"'"']+)["'"'"'])?/ig) {
      my ($rel, $href, $type) = (lc($1), $2, lc($3 // ""));
      my $group = 3;
      $group = 0 if $rel =~ /\bicon\b/ && $rel !~ /apple-touch-icon/;
      $group = 1 if $rel =~ /shortcut icon/;
      $group = 2 if $rel =~ /apple-touch-icon/;
      print $group . "\t" . $index++ . "\t" . $href . "\n" unless $seen{$href}++;
    }
    while (/<link\b[^>]*href=["'"'"']([^"'"'"']+)["'"'"'][^>]*rel=["'"'"']([^"'"'"']*(?:apple-touch-icon|icon|shortcut icon)[^"'"'"']*)["'"'"'][^>]*?(?:type=["'"'"']([^"'"'"']+)["'"'"'])?/ig) {
      my ($href, $rel, $type) = ($1, lc($2), lc($3 // ""));
      my $group = 3;
      $group = 0 if $rel =~ /\bicon\b/ && $rel !~ /apple-touch-icon/;
      $group = 1 if $rel =~ /shortcut icon/;
      $group = 2 if $rel =~ /apple-touch-icon/;
      print $group . "\t" . $index++ . "\t" . $href . "\n" unless $seen{$href}++;
    }
    while (/<meta\b[^>]*(?:property|name)=["'"'"'](?:og:image|twitter:image)["'"'"'][^>]*content=["'"'"']([^"'"'"']+)["'"'"']/ig) {
      my $href = $1;
      print "9\t" . $index++ . "\t" . $href . "\n" unless $seen{$href}++;
    }
  ' | sort -t$'\t' -k1,1n -k2,2n | cut -f3-
}

download_icon_candidate() {
  local icon_url="$1"
  local mime_type
  local raw_icon_file

  [[ -z "${icon_url}" ]] && return 1
  raw_icon_file="${SESSION_DIR}/raw-icon-download"
  rm -f "${raw_icon_file}" "${AUTO_ICON_FILE}"

  if curl -fsSL --max-time 20 -A "${USER_AGENT}" "${icon_url}" -o "${raw_icon_file}"; then
    mime_type="$(file --brief --mime-type "${raw_icon_file}" 2>/dev/null || true)"
    case "${mime_type}" in
      image/png|image/jpeg|image/vnd.microsoft.icon|image/x-icon)
        if sips -s format png "${raw_icon_file}" --out "${AUTO_ICON_FILE}" >/dev/null 2>&1; then
          ICON_FILE="${AUTO_ICON_FILE}"
          AUTO_ICON_DOWNLOADED=true
          info "Icono descargado desde ${icon_url}"
          rm -f "${raw_icon_file}"
          return 0
        fi
        ;;
      image/*)
        if sips -s format png "${raw_icon_file}" --out "${AUTO_ICON_FILE}" >/dev/null 2>&1; then
          ICON_FILE="${AUTO_ICON_FILE}"
          AUTO_ICON_DOWNLOADED=true
          info "Icono descargado desde ${icon_url}"
          rm -f "${raw_icon_file}"
          return 0
        fi
        ;;
    esac

    if [[ -f "${AUTO_ICON_FILE}" ]]; then
      case "$(file --brief --mime-type "${AUTO_ICON_FILE}" 2>/dev/null || true)" in
      image/png|image/jpeg)
        ICON_FILE="${AUTO_ICON_FILE}"
        AUTO_ICON_DOWNLOADED=true
        info "Icono descargado desde ${icon_url}"
        rm -f "${raw_icon_file}"
        return 0
        ;;
      esac
    fi
  fi

  rm -f "${raw_icon_file}"
  rm -f "${AUTO_ICON_FILE}"
  return 1
}

append_known_icon_candidates() {
  local host="$1"
  local array_name="$2"

  case "${host}" in
    chat.deepseek.com)
      eval "${array_name}+=(\"https://cdn.deepseek.com/chat/icon.png\")"
      eval "${array_name}+=(\"https://fe-static.deepseek.com/chat/favicon.svg\")"
      ;;
  esac
}

download_icon_if_needed() {
  local origin icon_url host
  local -a icon_candidates=()

  if [[ -n "${ICON_FILE}" ]]; then
    [[ -f "${ICON_FILE}" ]] || die "El icono indicado no existe: ${ICON_FILE}"
    return
  fi

  origin="$(extract_origin "${APP_URL}")"
  host="$(extract_host "${APP_URL}" | tr '[:upper:]' '[:lower:]')"
  AUTO_ICON_FILE="${SESSION_DIR}/${APP_SLUG}-icon.png"

  while IFS= read -r icon_url; do
    [[ -n "${icon_url}" ]] || continue
    icon_candidates+=("$(resolve_url "${APP_URL}" "${icon_url}")")
  done < <(discover_icon_candidates_from_html "${APP_URL}" || true)

  append_known_icon_candidates "${host}" icon_candidates

  icon_candidates+=(
    "${origin}/apple-touch-icon.png"
    "${origin}/android-chrome-512x512.png"
    "${origin}/icon-512.png"
    "${origin}/favicon.png"
    "${origin}/favicon.ico"
  )

  for icon_url in "${icon_candidates[@]}"; do
    download_icon_candidate "${icon_url}" && return
  done

  warn "No se pudo obtener un icono PNG/JPEG reutilizable. Se usara el icono por defecto de Electron."
}

create_menu_file() {
  MENU_FILE="${SESSION_DIR}/menu.js"
  cat > "${MENU_FILE}" <<EOF
module.exports = [
  {
    label: "$(printf '%s' "${APP_NAME}" | sed 's/\\/\\\\/g; s/"/\\"/g')",
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
}

clear_nativefier_cache_if_requested() {
  if [[ "${CLEAR_NATIVEFIER_CACHE}" == true ]]; then
    info "Limpiando cache de Nativefier..."
    rm -rf "${HOME}/.cache/nativefier" || true
  fi
}

preflight_checks() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Este script esta pensado para macOS."

  require_command npx
  require_command curl
  require_command file
  require_command mktemp
  require_command perl
  require_command sips

  if [[ "${CREATE_DMG}" == true ]]; then
    require_command hdiutil
  fi

  if [[ "${GENERATE_PWA}" == true ]]; then
    require_command iconutil
    require_command python3
  fi
}

prepare_output_dir() {
  if [[ -d "${OUTPUT_DIR}" ]]; then
    info "Eliminando generacion anterior en ${OUTPUT_DIR}..."
    rm -rf "${OUTPUT_DIR}"
  fi
}

create_build_session() {
  mkdir -p "${OUTPUT_DIR}"
  SESSION_DIR="$(mktemp -d "${OUTPUT_DIR}/.build.XXXXXX")"
}

auto_detect_auth_domains_if_needed() {
  local detected_file domain count=0 existing_count
  existing_count=${#EXTRA_INTERNAL_DOMAINS[@]}

  [[ -n "${RAW_INTERNAL_URLS_REGEX}" ]] && return 0

  if [[ ! -x "${AUTH_DETECTOR}" ]]; then
    warn "No se encontro el detector de autenticacion: ${AUTH_DETECTOR}. Se continua sin auto-deteccion."
    return 0
  fi

  detected_file="$(mktemp "${SESSION_DIR}/auth-domains.XXXXXX")"
  if ! "${AUTH_DETECTOR}" "${APP_URL}" "${USER_AGENT}" > "${detected_file}"; then
    warn "La auto-deteccion de autenticacion fallo. Se continua sin dominios extra."
    return 0
  fi

  while IFS= read -r domain; do
    domain="$(trim "${domain}")"
    [[ -n "${domain}" ]] || continue
    append_unique_domain "${domain}"
    count=$((count + 1))
  done < "${detected_file}"

  if [[ ${#EXTRA_INTERNAL_DOMAINS[@]} -gt ${existing_count} ]]; then
    info "Dominios de autenticacion finales: ${EXTRA_INTERNAL_DOMAINS[*]}"
  elif [[ ${existing_count} -gt 0 ]]; then
    info "No se detectaron dominios de autenticacion alternativos. Se usan los dominios indicados manualmente."
  else
    info "No se detectaron dominios de autenticacion adicionales."
  fi
}

run_nativefier_build() {
  local internal_urls_regex
  local -a nativefier_cmd=()

  auto_detect_auth_domains_if_needed
  internal_urls_regex="${RAW_INTERNAL_URLS_REGEX:-$(build_internal_urls_regex)}"

  nativefier_cmd=(
    npx
    --yes
    nativefier
    "${APP_URL}"
    --name "${APP_NAME}"
    --app-bundle-id "${BUNDLE_ID}"
    --app-version "${APP_VERSION}"
    --user-agent "${USER_AGENT}"
    --darwin-dark-mode-support
    --single-instance
    --menu "${MENU_FILE}"
    --platform mac
    --overwrite
    --internal-urls "${internal_urls_regex}"
  )

  if [[ -n "${ICON_FILE}" && -f "${ICON_FILE}" ]]; then
    nativefier_cmd+=(--icon "${ICON_FILE}")
  fi

  if [[ ${#EXTRA_NATIVEFIER_ARGS[@]} -gt 0 ]]; then
    nativefier_cmd+=("${EXTRA_NATIVEFIER_ARGS[@]}")
  fi

  info "Generando app con Nativefier..."

  (
    cd "${SESSION_DIR}"
    "${nativefier_cmd[@]}"
  )

  BUILD_OUTPUT_DIR="$(
    find "${SESSION_DIR}" -mindepth 1 -maxdepth 1 -type d -name "${APP_NAME}-darwin*" \
      | head -n 1
  )"

  [[ -n "${BUILD_OUTPUT_DIR}" ]] || die "No se encontro la carpeta de salida de Nativefier."
  info "Salida detectada en ${BUILD_OUTPUT_DIR}"
}

stage_app() {
  local built_app_path

  built_app_path="${BUILD_OUTPUT_DIR}/${APP_NAME}.app"
  [[ -d "${built_app_path}" ]] || die "No se encontro la app generada: ${built_app_path}"

  mkdir -p "${OUTPUT_DIR}"
  info "Moviendo app a ${TARGET_PATH}..."
  [[ -e "${TARGET_PATH}" ]] && rm -rf "${TARGET_PATH}"
  mv "${built_app_path}" "${TARGET_PATH}"
}

create_unsigned_dmg_with_hdiutil() {
  local source_app="$1"
  local dmg_output="$2"
  local volume_name="$3"
  local dmg_stage

  dmg_stage="$(mktemp -d "${SESSION_DIR}/dmg-stage.XXXXXX")"
  cp -R "${source_app}" "${dmg_stage}/"
  ln -s /Applications "${dmg_stage}/Applications"

  hdiutil create \
    -volname "${volume_name}" \
    -srcfolder "${dmg_stage}" \
    -ov \
    -format UDZO \
    "${dmg_output}" >/dev/null
}

create_dmg_for_app() {
  local source_app="$1"
  local dmg_output="$2"
  local app_label="$3"
  local dmg_glob="$4"
  local create_dmg_help create_dmg_worked=false found_dmg

  mkdir -p "$(dirname "${dmg_output}")"
  info "Creando DMG para ${app_label}..."

  if command -v create-dmg >/dev/null 2>&1; then
    create_dmg_help="$(create-dmg --help 2>&1 || true)"

    if printf '%s' "${create_dmg_help}" | grep -Fq "<app> [destination]"; then
      if create-dmg "${source_app}" "$(dirname "${dmg_output}")" --overwrite --no-code-sign; then
        found_dmg="$(
          find "$(dirname "${dmg_output}")" -maxdepth 1 -type f -name "*.dmg" \
            | grep -E "${dmg_glob}" \
            | head -n 1 \
            || true
        )"

        if [[ -n "${found_dmg}" && "${found_dmg}" != "${dmg_output}" ]]; then
          mv -f "${found_dmg}" "${dmg_output}"
        fi

        if [[ -f "${dmg_output}" ]]; then
          create_dmg_worked=true
        fi
      fi
    fi
  fi

  if [[ "${create_dmg_worked}" != true ]]; then
    warn "create-dmg no estuvo disponible o fallo. Se usara hdiutil."
    create_unsigned_dmg_with_hdiutil "${source_app}" "${dmg_output}" "${app_label}"
  fi

  [[ -f "${dmg_output}" ]] || die "No se encontro el archivo DMG esperado."
  info "DMG generado en ${dmg_output}"
}

find_chrome_binary() {
  local candidate
  local -a candidates=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "${HOME}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  )

  for candidate in "${candidates[@]}"; do
    [[ -x "${candidate}" ]] && printf '%s\n' "${candidate}" && return 0
  done

  return 1
}

create_pwa_launcher_app() {
  local chrome_binary launcher_dir launcher_script plist_file resources_dir source_plist source_pkginfo
  local escaped_chrome_binary escaped_app_url

  chrome_binary="$(find_chrome_binary || true)"
  [[ -n "${chrome_binary}" ]] || die "No se encontro Google Chrome. No se puede generar la PWA."

  launcher_dir="${PWA_APP_PATH}/Contents/MacOS"
  resources_dir="${PWA_APP_PATH}/Contents/Resources"
  mkdir -p "${launcher_dir}"

  launcher_script="${launcher_dir}/${PWA_APP_NAME}"
  plist_file="${PWA_APP_PATH}/Contents/Info.plist"
  source_plist="${TARGET_PATH}/Contents/Info.plist"
  source_pkginfo="${TARGET_PATH}/Contents/PkgInfo"
  escaped_chrome_binary="$(printf '%s' "${chrome_binary}" | sed "s/'/'\\''/g")"
  escaped_app_url="$(printf '%s' "${APP_URL}" | sed "s/'/'\\''/g")"

  rm -rf "${PWA_APP_PATH}"
  mkdir -p "${launcher_dir}" "${resources_dir}"

  cat > "${launcher_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

CHROME_BINARY='${escaped_chrome_binary}'
APP_URL='${escaped_app_url}'
CHROME_USER_DATA_DIR="\${CHROME_USER_DATA_DIR:-\$HOME/Library/Application Support/Google/Chrome}"
LOCAL_STATE_FILE="\${CHROME_USER_DATA_DIR}/Local State"
CONFIGURED_PROFILE_DIRECTORY='$(printf '%s' "${PWA_CHROME_PROFILE_DIRECTORY}" | sed "s/'/'\\''/g")'

detect_profile_directory() {
  local detected=""

  if [[ -n "\${CHROME_PROFILE_DIRECTORY:-}" ]]; then
    printf '%s\n' "\${CHROME_PROFILE_DIRECTORY}"
    return 0
  fi

  if [[ -n "\${CONFIGURED_PROFILE_DIRECTORY}" ]]; then
    printf '%s\n' "\${CONFIGURED_PROFILE_DIRECTORY}"
    return 0
  fi

  if [[ -f "\${LOCAL_STATE_FILE}" ]] && command -v python3 >/dev/null 2>&1; then
    detected="$(
      python3 - "\${LOCAL_STATE_FILE}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    value = (data.get("profile") or {}).get("last_used") or ""
    if isinstance(value, str):
        print(value.strip())
except Exception:
    pass
PY
    )"
  fi

  if [[ -n "\${detected}" && -d "\${CHROME_USER_DATA_DIR}/\${detected}" ]]; then
    printf '%s\n' "\${detected}"
    return 0
  fi

  printf '%s\n' "Default"
}

PROFILE_DIRECTORY="\$(detect_profile_directory)"

# Reuse the normal Chrome profile and avoid some throttling behaviors that can
# make a standalone app window feel slower than a regular Chrome tab.
CHROME_ARGS=(
  "--user-data-dir=\${CHROME_USER_DATA_DIR}"
  "--profile-directory=\${PROFILE_DIRECTORY}"
  "--disable-background-timer-throttling"
  "--disable-backgrounding-occluded-windows"
  "--disable-renderer-backgrounding"
  "--app=\${APP_URL}"
)

exec "\${CHROME_BINARY}" "\${CHROME_ARGS[@]}" >/dev/null 2>&1 &
EOF
  chmod +x "${launcher_script}"

  if [[ -f "${source_plist}" ]]; then
    cp "${source_plist}" "${plist_file}"
  else
    cat > "${plist_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${PWA_APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}.pwa</string>
  <key>CFBundleDisplayName</key>
  <string>${PWA_APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${PWA_APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
  fi

  python3 - "${plist_file}" "${PWA_APP_NAME}" "${BUNDLE_ID}.pwa" "${APP_VERSION}" <<'PY'
import plistlib
import sys

plist_path, app_name, bundle_id, app_version = sys.argv[1:5]
with open(plist_path, "rb") as fh:
    data = plistlib.load(fh)

data["CFBundleExecutable"] = app_name
data["CFBundleIdentifier"] = bundle_id
data["CFBundleDisplayName"] = app_name
data["CFBundleIconFile"] = "AppIcon.icns"
data["CFBundleName"] = app_name
data["CFBundleShortVersionString"] = app_version
data["CFBundleVersion"] = app_version
data["NSHighResolutionCapable"] = True

with open(plist_path, "wb") as fh:
    plistlib.dump(data, fh)
PY

  if [[ -f "${source_pkginfo}" ]]; then
    cp "${source_pkginfo}" "${PWA_APP_PATH}/Contents/PkgInfo"
  fi

  if [[ -n "${PWA_ICON_ICNS}" && -f "${PWA_ICON_ICNS}" ]]; then
    cp "${PWA_ICON_ICNS}" "${resources_dir}/AppIcon.icns"
  fi

  info "PWA creada en ${PWA_APP_PATH}"
}

generate_pwa_icon_if_possible() {
  local source_image icon_workspace iconset_dir source_iconset png_source icon_png
  local size

  [[ "${GENERATE_PWA}" == true ]] || return 0

  source_image="${TARGET_PATH}/Contents/Resources/electron.icns"
  if [[ ! -f "${source_image}" ]]; then
    source_image="${ICON_FILE}"
  fi
  [[ -n "${source_image}" && -f "${source_image}" ]] || return 0

  icon_workspace="${SESSION_DIR}/pwa-icon"
  iconset_dir="${icon_workspace}/AppIcon.iconset"
  mkdir -p "${iconset_dir}"

  if [[ "${source_image##*.}" == "icns" ]]; then
    source_iconset="${icon_workspace}/Source.iconset"
    if ! iconutil -c iconset "${source_image}" -o "${source_iconset}" >/dev/null 2>&1; then
      source_iconset=""
    fi
  fi

  if [[ -n "${source_iconset:-}" && -d "${source_iconset}" ]]; then
    cp -R "${source_iconset}/." "${iconset_dir}/"
  else
    png_source="${icon_workspace}/source.png"
    if ! sips -s format png "${source_image}" --out "${png_source}" >/dev/null 2>&1; then
      warn "No se pudo convertir el icono a PNG para la PWA. La PWA se generara sin icono personalizado."
      return 0
    fi

    for size in 16 32 128 256 512; do
      sips -z "${size}" "${size}" "${png_source}" --out "${iconset_dir}/icon_${size}x${size}.png" >/dev/null 2>&1 || return 0
    done

    sips -z 32 32 "${png_source}" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null 2>&1 || return 0
    sips -z 64 64 "${png_source}" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null 2>&1 || return 0
    sips -z 256 256 "${png_source}" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null 2>&1 || return 0
    sips -z 512 512 "${png_source}" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null 2>&1 || return 0
    sips -z 1024 1024 "${png_source}" --out "${iconset_dir}/icon_512x512@2x.png" >/dev/null 2>&1 || return 0
  fi

  while IFS= read -r icon_png; do
    [[ -n "${icon_png}" ]] || continue
    if ! python3 - "${icon_png}" <<'PY'
from PIL import Image, ImageDraw
import sys

icon_path = sys.argv[1]
img = Image.open(icon_path).convert("RGBA")
w, h = img.size

draw = ImageDraw.Draw(img, "RGBA")
alpha = img.split()[3]

# Slightly larger corner badge while keeping the original icon untouched.
side = min(w, h)
size = max(6, int(side * 0.21))

# Keep the badge inside the visible icon shape.
# Some app icons have transparent rounded corners; if we place the badge at
# the extreme bottom-right it can be clipped and appear to disappear.
diag_inset = 0
limit = max(1, side // 2)
for i in range(limit):
    x = w - 1 - i
    y = h - 1 - i
    if x < 0 or y < 0:
        break
    if alpha.getpixel((x, y)) > 24:
        diag_inset = i
        break

base_pad = max(6, int(side * 0.012))
safe_pad = max(base_pad, diag_inset + max(2, int(side * 0.01)))

# Move the badge inward so it sits closer to the logo instead of hugging
# the extreme rounded corner.
visual_inset = max(2, int(side * 0.025))
pad = safe_pad + visual_inset

left = w - size - pad
top = h - size - pad
right = w - pad
bottom = h - pad

if left < 0:
    shift = -left
    left += shift
    right += shift
if top < 0:
    shift = -top
    top += shift
    bottom += shift
if right > w - 1:
    shift = right - (w - 1)
    right -= shift
    left -= shift
if bottom > h - 1:
    shift = bottom - (h - 1)
    bottom -= shift
    top -= shift

a = (right, top)
b = (right, bottom)
c = (left, bottom)
centroid = ((a[0] + b[0] + c[0]) // 3, (a[1] + b[1] + c[1]) // 3)

draw.polygon([a, centroid, c], fill=(239, 68, 68, 240))
draw.polygon([a, b, centroid], fill=(34, 197, 94, 240))
draw.polygon([centroid, b, c], fill=(59, 130, 246, 240))

border_w = max(1, int(min(w, h) * 0.0025))
half_border_w = 1

# Full black perimeter as base.
draw.line([a, b], fill=(0, 0, 0, 245), width=border_w)
draw.line([b, c], fill=(0, 0, 0, 245), width=border_w)
draw.line([c, a], fill=(0, 0, 0, 245), width=border_w)

# White half-border on the top and diagonal edges for contrast.
draw.line([a, ((a[0] + b[0]) // 2, (a[1] + b[1]) // 2)], fill=(255, 255, 255, 245), width=half_border_w)
draw.line([((c[0] + a[0]) // 2, (c[1] + a[1]) // 2), a], fill=(255, 255, 255, 245), width=half_border_w)

img.save(icon_path)
PY
    then
      warn "No se pudo generar el badge del icono PWA en ${icon_png}. Se conserva ese tamano sin cambios."
    fi
  done < <(find "${iconset_dir}" -type f -name '*.png' | sort)

  PWA_ICON_ICNS="${icon_workspace}/AppIcon.icns"
  if ! iconutil -c icns "${iconset_dir}" -o "${PWA_ICON_ICNS}" >/dev/null 2>&1; then
    warn "No se pudo generar el archivo .icns para la PWA. La PWA se generara sin icono personalizado."
    PWA_ICON_ICNS=""
  fi
}

create_pwa_if_requested() {
  [[ "${GENERATE_PWA}" == true ]] || return 0

  create_pwa_launcher_app

  if [[ "${CREATE_DMG}" == true ]]; then
    create_dmg_for_app "${PWA_APP_PATH}" "${PWA_DMG_OUTPUT}" "${PWA_APP_NAME}" "/${PWA_APP_NAME}.*\\.dmg$"
  fi
}

create_dmg_if_requested() {
  [[ "${CREATE_DMG}" == true ]] || return 0
  create_dmg_for_app "${TARGET_PATH}" "${DMG_OUTPUT}" "${APP_NAME}" "/${APP_NAME}.*\\.dmg$"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        APP_URL="${2:-}"
        shift 2
        ;;
      --name)
        APP_NAME="${2:-}"
        shift 2
        ;;
      --bundle-id)
        BUNDLE_ID="${2:-}"
        shift 2
        ;;
      --version)
        APP_VERSION="${2:-}"
        shift 2
        ;;
      --icon)
        ICON_FILE="${2:-}"
        shift 2
        ;;
      --dmg-output)
        DMG_OUTPUT="${2:-}"
        shift 2
        ;;
      --internal-domain)
        append_unique_domain "${2:-}"
        shift 2
        ;;
      --internal-urls-regex)
        RAW_INTERNAL_URLS_REGEX="${2:-}"
        shift 2
        ;;
      --user-agent)
        USER_AGENT="${2:-}"
        shift 2
        ;;
      --chrome-profile-directory)
        PWA_CHROME_PROFILE_DIRECTORY="${2:-}"
        shift 2
        ;;
      --no-dmg)
        CREATE_DMG=false
        shift
        ;;
      --generate-pwa)
        GENERATE_PWA=true
        shift
        ;;
      --keep-build-artifacts)
        KEEP_BUILD_ARTIFACTS=true
        shift
        ;;
      --keep-nativefier-cache)
        CLEAR_NATIVEFIER_CACHE=false
        shift
        ;;
      --install-dir)
        DEPRECATED_INSTALL_FLAG_USED=true
        shift 2
        ;;
      --no-install)
        DEPRECATED_INSTALL_FLAG_USED=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        EXTRA_NATIVEFIER_ARGS+=("$@")
        break
        ;;
      *)
        die "Argumento no reconocido: $1"
        ;;
    esac
  done
}

validate_config() {
  [[ -n "${APP_URL}" ]] || die "Debes indicar --url."
  [[ "${APP_URL}" =~ ^https?:// ]] || die "La URL debe comenzar con http:// o https://."

  if [[ -z "${APP_NAME}" ]]; then
    APP_NAME="$(derive_app_name_from_url "${APP_URL}")"
  fi

  APP_SLUG="$(sanitize_slug "${APP_NAME}")"
  [[ -n "${APP_SLUG}" ]] || die "No se pudo derivar un slug valido para la app."

  if [[ -z "${BUNDLE_ID}" ]]; then
    BUNDLE_ID="com.local.webclone.${APP_SLUG}"
  fi

  if is_google_embedded_login_target "${APP_URL}"; then
    KNOWN_EMBEDDED_LOGIN_LIMITS=true
    warn "Google/Gemini suele bloquear el inicio de sesion en navegadores embebidos como Electron/Nativefier."
    warn "Este script puede construir la app, pero no puede reutilizar la sesion actual de Chrome/Safari ni garantizar login dentro de Gemini."
    warn "La alternativa fiable para Gemini es usar Chrome directamente, por ejemplo como PWA o con un lanzador de Chrome --app."
  fi

  OUTPUT_DIR="${OUTPUT_ROOT_DIR}/${APP_NAME}"
  TARGET_PATH="${OUTPUT_DIR}/${APP_NAME}.app"
  PWA_APP_NAME="${APP_NAME} PWA"
  PWA_APP_PATH="${OUTPUT_DIR}/${PWA_APP_NAME}.app"
  PWA_DMG_OUTPUT="${OUTPUT_DIR}/$(default_pwa_dmg_filename)"

  if [[ -z "${DMG_OUTPUT}" ]]; then
    DMG_OUTPUT="${OUTPUT_DIR}/$(default_dmg_filename)"
  else
    if [[ "${DMG_OUTPUT}" != /* ]]; then
      DMG_OUTPUT="${SCRIPT_DIR}/${DMG_OUTPUT}"
    fi

    if [[ "${DMG_OUTPUT}" == */ || -d "${DMG_OUTPUT}" ]]; then
      DMG_OUTPUT="${DMG_OUTPUT%/}/$(default_dmg_filename)"
    fi
  fi

  if [[ "${DEPRECATED_INSTALL_FLAG_USED}" == true ]]; then
    warn "Las opciones --install-dir y --no-install estan deprecadas y ahora se ignoran. La app siempre se guarda en ${OUTPUT_DIR}."
  fi

  if [[ "${GENERATE_PWA}" == true ]]; then
    info "Se generara tambien una PWA basada en Google Chrome para reutilizar la sesion del navegador."
  fi
}

main() {
  parse_args "$@"
  validate_config
  preflight_checks
  prepare_output_dir
  create_build_session
  clear_nativefier_cache_if_requested
  download_icon_if_needed
  create_menu_file
  run_nativefier_build
  stage_app
  generate_pwa_icon_if_possible
  create_dmg_if_requested
  create_pwa_if_requested

  info "Proceso completado."
  info "App disponible en ${TARGET_PATH}"
  if [[ "${CREATE_DMG}" == true ]]; then
    info "DMG disponible en ${DMG_OUTPUT}"
  fi
  if [[ "${GENERATE_PWA}" == true ]]; then
    info "PWA disponible en ${PWA_APP_PATH}"
    if [[ "${CREATE_DMG}" == true ]]; then
      info "DMG de la PWA disponible en ${PWA_DMG_OUTPUT}"
    fi
  fi
  if [[ "${KNOWN_EMBEDDED_LOGIN_LIMITS}" == true ]]; then
    warn "Recordatorio: para Gemini/Google el bloqueo de login depende de la politica de Google sobre navegadores embebidos."
  fi
}

main "$@"
