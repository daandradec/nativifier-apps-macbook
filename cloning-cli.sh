#!/usr/bin/env bash
# ------------------------------------------------------------
# cloning-cli.sh
# Empaqueta una app macOS con Nativefier o guía la instalación en Chrome.
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
APP_MODE=nativefier
KEEP_BUILD_ARTIFACTS=false
CLEAR_NATIVEFIER_CACHE=true
DMG_OUTPUT=""
RAW_INTERNAL_URLS_REGEX=""
PWA_CHROME_PROFILE_DIRECTORY=""
OUTPUT_ROOT_DIR="${SCRIPT_DIR}/output"
OUTPUT_DIR=""
DEPRECATED_INSTALL_FLAG_USED=false
KNOWN_EMBEDDED_LOGIN_LIMITS=false

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
  bash cloning-cli.sh --url URL --pwa
  bash cloning-cli.sh --url URL --chrome-window-simple [--no-dmg]
  bash cloning-cli.sh --url URL --pwa-manual-guide [--chrome-profile-directory X]
  bash cloning-cli.sh --suggest-name URL  # Muestra el nombre por defecto sin generar archivos.

Opciones:
  --url URL                     URL del sitio. Requerido.
  --name NAME                   Nombre de la app. Si se omite, se deriva del dominio.
  --bundle-id ID                Bundle ID de macOS. Default: com.local.webclone.<slug>
  --version VERSION             Version de la app/DMG. Default: 1.0.0
  --icon PATH                   Ruta a un icono local PNG/JPG/JPEG o ICNS.
  --dmg-output PATH             Ruta del DMG final. Solo afecta al DMG.
  --internal-domain HOST        Dominio adicional que debe abrirse dentro de la app.
                                Repetible. Util para SSO/OAuth.
  --internal-urls-regex REGEX   Regex completa para Nativefier --internal-urls.
  --user-agent STRING           User-Agent custom para iconos y Nativefier.
  --no-dmg                      No crear DMG.
  --pwa                         Instala una PWA real mediante Chrome en un perfil separado.
  --chrome-window-simple        Empaqueta un acceso Chrome --app; no registra una PWA.
  --pwa-manual-guide            Abre Chrome y muestra los pasos de instalación manual.
  --chrome-profile-directory X  Perfil para --pwa-manual-guide (ej: Default o Profile 1).
  --keep-build-artifacts        Conserva archivos temporales de compilacion.
  --keep-nativefier-cache       No borra la cache de Nativefier antes de compilar.
  --install-dir PATH            Opcion deprecada; ahora se ignora.
  --no-install                  Opcion deprecada; ahora se ignora.
  -h, --help                    Muestra esta ayuda.

Salidas de empaquetado:
  - App: ./output/<AppName>/<AppName>.app
  - DMG: ./output/<AppName>/<AppName> <version>.dmg
  - --chrome-window-simple usa ./output/<AppName> (Chrome Window Simple)/.
  - --dmg-output solo cambia la ruta del DMG, no la carpeta de la app.

Notas:
  - Todo lo que venga despues de -- se pasa directo a Nativefier.
  - En el build de Nativefier, si no defines --internal-urls-regex,
    search-auth-domain intenta detectar dominios de autenticacion.

Ejemplos:
  bash cloning-cli.sh --url https://github.com/ --pwa

  ./cloning-cli.sh \
    --url https://chat.openai.com \
    --name ChatGPTDesktop

  ./cloning-cli.sh \
    --url https://app.example.com \
    --name ExampleApp \
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

  host="$(extract_host "${url}" | tr '[:upper:]' '[:lower:]')"
  host="${host#www.}"

  case "${host}" in
    github.com)
      printf '%s\n' GitHub
      return 0
      ;;
  esac

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

append_unique_domain() {
  local candidate="$1"
  local existing

  candidate="$(trim "${candidate}")"
  [[ -n "${candidate}" ]] || return 0

  if [[ ${#EXTRA_INTERNAL_DOMAINS[@]} -gt 0 ]]; then
    for existing in "${EXTRA_INTERNAL_DOMAINS[@]}"; do
      [[ "${existing}" == "${candidate}" ]] && return 0
    done
  fi

  EXTRA_INTERNAL_DOMAINS+=("${candidate}")
}

build_internal_urls_regex() {
  local domains=()
  local host escaped joined=""

  host="$(extract_host "${APP_URL}")"
  domains+=("${host}")
  if [[ ${#EXTRA_INTERNAL_DOMAINS[@]} -gt 0 ]]; then
    domains+=("${EXTRA_INTERNAL_DOMAINS[@]}")
  fi

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

  warn "No se pudo obtener un icono reutilizable del sitio. Se usara el icono por defecto."
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

check_node_version() {
  local node_version node_major

  node_version="$(node -v 2>/dev/null || true)"
  node_major="${node_version#v}"
  node_major="${node_major%%.*}"

  if [[ "${node_major}" =~ ^[0-9]+$ ]] && (( node_major >= 26 )); then
    warn "Se encontro Node ${node_version}. La version ideal para ejecutar este script con Nativefier es Node 24 (ej: nvm use 24)."
  fi
}

preflight_checks() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Este script esta pensado para macOS."

  if [[ "${APP_MODE}" == chrome-window-simple ]]; then
    find_chrome_binary >/dev/null || die "No se encontro Google Chrome."
    require_command python3
  else
    require_command node
    require_command npx
  fi
  require_command curl
  require_command file
  require_command mktemp
  require_command perl
  require_command sips

  if [[ "${CREATE_DMG}" == true ]]; then
    require_command hdiutil
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

  if [[ -z "${BUILD_OUTPUT_DIR}" ]]; then
    check_node_version
    die "No se encontro la carpeta de salida de Nativefier."
  fi
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

guide_pwa_install() {
  local chrome_binary chrome_bundle profile="${PWA_CHROME_PROFILE_DIRECTORY}"

  [[ "$(uname -s)" == Darwin ]] || die "La instalacion guiada requiere macOS."
  chrome_binary="$(find_chrome_binary)" || die "No se encontro Google Chrome."
  chrome_bundle="${chrome_binary%/Contents/MacOS/Google Chrome}"

  if [[ -n "${profile}" ]]; then
    case "${profile}" in
      .|..|*/*) die "Usa el nombre del directorio del perfil, por ejemplo Default o Profile 1." ;;
    esac
    [[ -d "${HOME}/Library/Application Support/Google/Chrome/${profile}" ]] ||
      die "No se encontro el perfil de Chrome «${profile}»."
  fi

  info "Abriendo ${APP_URL} en Google Chrome."
  info "En Chrome: ⋮ → Enviar, guardar y compartir → Instalar página como aplicación."
  info "Confirma el nombre y la instalacion en Chrome. Este modo no crea un DMG."
  if [[ -n "${profile}" ]]; then
    # -n hands the explicit profile and URL to Chrome's existing-session
    # routing even if the browser is already running.
    /usr/bin/open -n -a "${chrome_bundle}" --args "--profile-directory=${profile}" "${APP_URL}"
  else
    /usr/bin/open -a "${chrome_bundle}" "${APP_URL}"
  fi
}

install_real_pwa() {
  local chrome_binary
  [[ "$(uname -s)" == Darwin ]] || die "La instalacion PWA requiere macOS."
  require_command python3
  chrome_binary="$(find_chrome_binary)" || die "No se encontro Google Chrome."
  info "Buscando la PWA en ${APP_URL}. Si no está instalada, Chrome usará un perfil nuevo."
  python3 "${SCRIPT_DIR}/install_chrome_pwa.py" "${chrome_binary}" "${APP_URL}"
}

create_chrome_window_app() {
  local contents="${TARGET_PATH}/Contents" icon="${ICON_FILE:-${AUTO_ICON_FILE}}"
  local icon_name=""
  mkdir -p "${contents}/MacOS" "${contents}/Resources"
  {
    printf '#!/bin/bash\nset -eu\n'
    printf 'APP_URL=%q\n' "${APP_URL}"
    cat <<'EOF'
exec /usr/bin/open -g -n -b com.google.Chrome --args "--app=${APP_URL}"
EOF
  } >"${contents}/MacOS/Launch"
  chmod +x "${contents}/MacOS/Launch"
  if [[ -n "${icon}" && -f "${icon}" ]]; then
    if [[ "${icon}" == *.icns ]]; then
      cp "${icon}" "${contents}/Resources/AppIcon.icns"
      icon_name=AppIcon.icns
    elif sips -s format icns "${icon}" --out "${contents}/Resources/AppIcon.icns" >/dev/null 2>&1; then
      icon_name=AppIcon.icns
    else
      warn "No se pudo convertir el icono; se usara el de macOS."
    fi
  fi
  python3 - "${contents}/Info.plist" "${APP_NAME}" "${BUNDLE_ID}" "${APP_VERSION}" "${icon_name}" <<'PY'
import plistlib
import sys

path, name, bundle_id, version, icon = sys.argv[1:]
data = {"CFBundleName": name, "CFBundleDisplayName": name,
        "CFBundleExecutable": "Launch", "CFBundleIdentifier": bundle_id,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
        "CFBundleVersion": version}
if icon:
    data["CFBundleIconFile"] = icon
with open(path, "wb") as f:
    plistlib.dump(data, f)
PY
}

create_dmg_if_requested() {
  [[ "${CREATE_DMG}" == true ]] || return 0
  create_dmg_for_app "${TARGET_PATH}" "${DMG_OUTPUT}" "${APP_NAME}" "/${APP_NAME}.*\\.dmg$"
}

select_app_mode() {
  [[ "${APP_MODE}" == nativefier || "${APP_MODE}" == "$1" ]] ||
    die "Elige un solo modo: --pwa, --chrome-window-simple o --pwa-manual-guide."
  APP_MODE="$1"
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
      --pwa)
        select_app_mode pwa
        shift
        ;;
      --chrome-window-simple)
        select_app_mode chrome-window-simple
        shift
        ;;
      --pwa-manual-guide|--install-pwa)
        select_app_mode pwa-manual-guide
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
  local default_filename

  if [[ -z "${APP_NAME}" ]]; then
    APP_NAME="$(derive_app_name_from_url "${APP_URL}")"
  fi

  APP_SLUG="$(sanitize_slug "${APP_NAME}")"
  [[ -n "${APP_SLUG}" ]] || die "No se pudo derivar un slug valido para la app."

  if [[ -z "${BUNDLE_ID}" ]]; then
    BUNDLE_ID="com.local.webclone.${APP_SLUG}"
    # Preserve the bundle identity of apps built before the mode was renamed.
    [[ "${APP_MODE}" != chrome-window-simple ]] || BUNDLE_ID+=".pwa-basic"
  fi

  if [[ "${APP_MODE}" == nativefier ]] && is_google_embedded_login_target "${APP_URL}"; then
    KNOWN_EMBEDDED_LOGIN_LIMITS=true
    warn "Google/Gemini suele bloquear el inicio de sesion en navegadores embebidos como Electron/Nativefier."
    warn "Este script puede construir la app, pero no puede reutilizar la sesion actual de Chrome/Safari ni garantizar login dentro de Gemini."
    warn "La alternativa es instalar la app web en Chrome con --pwa o --pwa-manual-guide."
  fi

  OUTPUT_DIR="${OUTPUT_ROOT_DIR}/${APP_NAME}"
  if [[ "${APP_MODE}" == chrome-window-simple ]]; then
    [[ "${APP_NAME}" != */* ]] || die "El nombre de la app no puede contener /."
    OUTPUT_DIR+=" (Chrome Window Simple)"
  fi
  TARGET_PATH="${OUTPUT_DIR}/${APP_NAME}.app"
  default_filename="${APP_NAME} ${APP_VERSION}.dmg"

  if [[ -z "${DMG_OUTPUT}" ]]; then
    DMG_OUTPUT="${OUTPUT_DIR}/${default_filename}"
  else
    if [[ "${DMG_OUTPUT}" != /* ]]; then
      DMG_OUTPUT="${SCRIPT_DIR}/${DMG_OUTPUT}"
    fi

    if [[ "${DMG_OUTPUT}" == */ || -d "${DMG_OUTPUT}" ]]; then
      DMG_OUTPUT="${DMG_OUTPUT%/}/${default_filename}"
    fi
  fi

  if [[ "${DEPRECATED_INSTALL_FLAG_USED}" == true ]]; then
    warn "Las opciones --install-dir y --no-install estan deprecadas y ahora se ignoran. La app siempre se guarda en ${OUTPUT_DIR}."
  fi
}

main() {
  if [[ "${1:-}" == --suggest-name ]]; then
    [[ $# -eq 2 && "${2:-}" =~ ^https?:// ]] || die "Uso: --suggest-name URL"
    derive_app_name_from_url "$2"
    return
  fi

  parse_args "$@"
  [[ -n "${APP_URL}" ]] || die "Debes indicar --url."
  [[ "${APP_URL}" =~ ^https?:// ]] || die "La URL debe comenzar con http:// o https://."
  if [[ "${APP_MODE}" == pwa-manual-guide ]]; then
    guide_pwa_install
    return
  fi
  [[ -z "${PWA_CHROME_PROFILE_DIRECTORY}" ]] ||
    die "--chrome-profile-directory solo se usa con --pwa-manual-guide."
  if [[ "${APP_MODE}" == pwa ]]; then
    install_real_pwa
    return
  fi
  trap cleanup EXIT
  validate_config
  preflight_checks
  prepare_output_dir
  create_build_session
  download_icon_if_needed
  if [[ "${APP_MODE}" == chrome-window-simple ]]; then
    create_chrome_window_app
  else
    clear_nativefier_cache_if_requested
    create_menu_file
    run_nativefier_build
    stage_app
  fi
  create_dmg_if_requested

  info "Proceso completado."
  info "App disponible en ${TARGET_PATH}"
  if [[ "${CREATE_DMG}" == true ]]; then
    info "DMG disponible en ${DMG_OUTPUT}"
  fi
  if [[ "${KNOWN_EMBEDDED_LOGIN_LIMITS}" == true ]]; then
    warn "Recordatorio: para Gemini/Google el bloqueo de login depende de la politica de Google sobre navegadores embebidos."
  fi
}

main "$@"
