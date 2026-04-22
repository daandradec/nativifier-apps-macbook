#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SCRIPT="${SCRIPT_DIR}/cloning-cli.sh"
DEFAULT_USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

usage() {
  cat <<'EOF'
Uso:
  ./cloning-website-to-dmg.sh

Descripcion:
  Asistente interactivo que hace preguntas, arma el comando para
  `cloning-cli.sh` y luego lo ejecuta con los parametros elegidos.

Salidas por defecto:
  - App: ./output/<AppName>/<AppName>.app
  - DMG: ./output/<AppName>/<AppName> <version>.dmg
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[INFO] %s\n' "$*"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

split_csv_to_array() {
  local csv="$1"
  local array_name="$2"
  local item

  IFS=',' read -r -a parts <<< "${csv}"
  for item in "${parts[@]}"; do
    item="$(trim "${item}")"
    [[ -n "${item}" ]] || continue
    eval "${array_name}+=(\"\$item\")"
  done
}

PROMPT_RESULT=""
PROMPT_BACK_CODE=111

read_line_or_back() {
  local output rc

  if [[ ! -t 0 || ! -t 1 ]]; then
    read -r output || return 1
    PROMPT_RESULT="${output}"
    return 0
  fi

  if output="$(python3 - <<'PY'
import os
import select
import sys
import termios

BACK_CODE = 111
tty = open("/dev/tty", "rb+", buffering=0)
fd = tty.fileno()
old = termios.tcgetattr(fd)
answer = []

def write_err(text):
    tty.write(text.encode("utf-8", "ignore"))
    tty.flush()

def read_next(timeout=None):
    if timeout is not None:
        ready, _, _ = select.select([fd], [], [], timeout)
        if not ready:
            return b""
    try:
        return os.read(fd, 1)
    except OSError:
        return b""

try:
    new = termios.tcgetattr(fd)
    new[3] = new[3] & ~(termios.ICANON | termios.ECHO)
    new[6][termios.VMIN] = 1
    new[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSADRAIN, new)

    while True:
        ch = read_next()
        if not ch:
            raise SystemExit(1)

        if ch in (b"\r", b"\n"):
            write_err("\n")
            sys.stdout.write("".join(answer))
            raise SystemExit(0)

        if ch in (b"\x7f", b"\x08"):
            if not answer:
                write_err("\n")
                raise SystemExit(BACK_CODE)
            answer.pop()
            write_err("\b \b")
            continue

        if ch == b"\x1b":
            seq = b""
            while True:
                part = read_next(0.01)
                if not part:
                    break
                seq += part
                if seq.endswith(b"~"):
                    break
            if seq == b"[3~" and not answer:
                write_err("\n")
                raise SystemExit(BACK_CODE)
            continue

        if ch[0] < 32:
            continue

        text = ch.decode("utf-8", "ignore")
        if not text:
            continue
        answer.append(text)
        write_err(text)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    tty.close()
PY
)"; then
    rc=0
  else
    rc=$?
  fi

  if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
    return "${PROMPT_BACK_CODE}"
  fi
  [[ ${rc} -eq 0 ]] || return "${rc}"

  PROMPT_RESULT="${output}"
  return 0
}

prompt_text() {
  local summary="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local answer rc

  printf '\n%s\n' "${summary}" >&2
  if [[ -n "${default_value}" ]]; then
    printf '%s [%s]: ' "${prompt}" "${default_value}" >&2
  else
    printf '%s: ' "${prompt}" >&2
  fi

  read_line_or_back
  rc=$?
  if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
    return "${PROMPT_BACK_CODE}"
  fi
  [[ ${rc} -eq 0 ]] || return "${rc}"
  answer="${PROMPT_RESULT}"

  if [[ -z "${answer}" && -n "${default_value}" ]]; then
    answer="${default_value}"
  fi

  PROMPT_RESULT="$(trim "${answer}")"
  return 0
}

prompt_required() {
  local summary="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local answer="" rc

  while [[ -z "${answer}" ]]; do
    prompt_text "${summary}" "${prompt}" "${default_value}"
    rc=$?
    if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
      return "${PROMPT_BACK_CODE}"
    fi
    [[ ${rc} -eq 0 ]] || return "${rc}"
    answer="${PROMPT_RESULT}"
    [[ -n "${answer}" ]] || printf 'This field is required.\n' >&2
  done

  PROMPT_RESULT="${answer}"
  return 0
}

prompt_yes_no() {
  local summary="$1"
  local prompt="$2"
  local default_value="${3:-y}"
  local answer normalized empty_label rc

  if [[ "${default_value}" == "y" ]]; then
    empty_label="Y"
  else
    empty_label="N"
  fi

  while true; do
    printf '\n%s\n' "${summary}" >&2
    printf '%s [y/n, empty = %s]: ' "${prompt}" "${empty_label}" >&2
    read_line_or_back
    rc=$?
    if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
      return "${PROMPT_BACK_CODE}"
    fi
    [[ ${rc} -eq 0 ]] || return "${rc}"
    answer="${PROMPT_RESULT}"
    answer="${answer:-${default_value}}"
    normalized="$(trim "$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')")"

    case "${normalized}" in
      y|yes|s|si)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        printf 'Answer with y or n.\n' >&2
        ;;
    esac
  done
}

print_command() {
  local -a cmd=("$@")
  local rendered=""
  local part

  for part in "${cmd[@]}"; do
    rendered+=" $(printf '%q' "${part}")"
  done

  printf '%s\n' "${rendered# }"
}

main() {
  local app_url="" app_name="" bundle_id="" app_version="1.0.0" icon_file="" dmg_output=""
  local internal_domains_csv="" internal_urls_regex="" user_agent="${DEFAULT_USER_AGENT}" extra_arg=""
  local chrome_profile_directory=""
  local -a internal_domains=()
  local -a extra_nativefier_args=()
  local -a cmd=()
  local create_dmg=true
  local generate_pwa=false
  local keep_build_artifacts=false
  local keep_nativefier_cache=false
  local add_extra_nativefier_args=false
  local step=0
  local rc=0
  local domain

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  [[ -f "${CLI_SCRIPT}" ]] || die "No se encontro ${CLI_SCRIPT}"

  printf 'Interactive website-to-DMG builder\n'

  while true; do
    case "${step}" in
      0)
        if prompt_required \
          'Target website to package. This is the only required field.' \
          'Website URL (must start with http:// or https://)' \
          "${app_url}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=0
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        app_url="${PROMPT_RESULT}"
        if [[ ! "${app_url}" =~ ^https?:// ]]; then
          printf 'The URL must start with http:// or https://.\n' >&2
          continue
        fi
        step=1
        ;;
      1)
        if prompt_text \
          'App label used in the bundle name and the default output folder. Empty lets cloning-cli derive it from the domain.' \
          'App name' \
          "${app_name}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=0
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        app_name="${PROMPT_RESULT}"
        step=2
        ;;
      2)
        if prompt_text \
          'macOS bundle identifier. Empty auto-generates com.local.webclone.<slug>.' \
          'Bundle ID' \
          "${bundle_id}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=1
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        bundle_id="${PROMPT_RESULT}"
        step=3
        ;;
      3)
        if prompt_text \
          'Version used in app metadata and in the default DMG filename.' \
          'App version' \
          "${app_version}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=2
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        app_version="${PROMPT_RESULT}"
        step=4
        ;;
      4)
        if prompt_text \
          'Optional local PNG/JPG/JPEG icon. Empty tries to discover the site icon automatically.' \
          'Icon file path' \
          "${icon_file}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=3
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        icon_file="${PROMPT_RESULT}"
        step=5
        ;;
      5)
        if prompt_text \
          'User-Agent used by Nativefier and by icon discovery requests.' \
          'User-Agent' \
          "${user_agent}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=4
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        user_agent="${PROMPT_RESULT}"
        step=6
        ;;
      6)
        if prompt_yes_no \
          'Choose whether to create a DMG installer in the app output folder.' \
          'Create a DMG installer?' \
          'y'; then
          create_dmg=true
          step=7
        else
          rc=$?
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            step=5
            continue
          fi
          create_dmg=false
          dmg_output=""
          step=8
        fi
        ;;
      7)
        if prompt_text \
          'Optional override for the DMG file path only. Empty keeps the default under ./output/<AppName>/.' \
          'DMG output path' \
          "${dmg_output}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=6
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        dmg_output="${PROMPT_RESULT}"
        step=8
        ;;
      8)
        if prompt_text \
          'Optional external authentication domains to keep inside the app. Use commas if there are multiple. Even if you fill this field, cloning-cli will still check for possible additional auth domains automatically unless you override the full regex.' \
          'Authentication domains' \
          "${internal_domains_csv}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          if [[ "${create_dmg}" == true ]]; then
            step=7
          else
            step=6
          fi
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        internal_domains_csv="${PROMPT_RESULT}"
        internal_domains=()
        split_csv_to_array "${internal_domains_csv}" internal_domains
        step=9
        ;;
      9)
        if prompt_text \
          'Optional full override for Nativefier --internal-urls. If you set this, automatic auth-domain detection is skipped.' \
          'Internal URLs regex override' \
          "${internal_urls_regex}"; then
          rc=0
        else
          rc=$?
        fi
        if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
          step=8
          continue
        fi
        [[ ${rc} -eq 0 ]] || exit "${rc}"
        internal_urls_regex="${PROMPT_RESULT}"
        step=10
        ;;
      10)
        if prompt_yes_no \
          'If this site has strong authentication or blocks embedded browsers, generate a Chrome-based PWA launcher too. Default is No.' \
          'Generate PWA too because this website has strong authentication?' \
          'n'; then
          generate_pwa=true
        else
          rc=$?
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            step=9
            continue
          fi
          generate_pwa=false
        fi
        step=11
        ;;
      11)
        if [[ "${generate_pwa}" == true ]]; then
          if prompt_text \
            'Optional Chrome profile directory for the generated PWA. Example: Default or Profile 1. Empty auto-detects the last-used Chrome profile at launch time.' \
            'Chrome profile directory for PWA' \
            "${chrome_profile_directory}"; then
            rc=0
          else
            rc=$?
          fi
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            step=10
            continue
          fi
          [[ ${rc} -eq 0 ]] || exit "${rc}"
          chrome_profile_directory="${PROMPT_RESULT}"
        else
          chrome_profile_directory=""
        fi
        step=12
        ;;
      12)
        if prompt_yes_no \
          'Keep temporary build folders created during the build. Useful for debugging Nativefier output.' \
          'Keep temporary build artifacts?' \
          'n'; then
          keep_build_artifacts=true
        else
          rc=$?
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            if [[ "${generate_pwa}" == true ]]; then
              step=11
            else
              step=10
            fi
            continue
          fi
          keep_build_artifacts=false
        fi
        step=13
        ;;
      13)
        if prompt_yes_no \
          'Keep the Nativefier cache instead of clearing it before the build.' \
          'Keep Nativefier cache?' \
          'n'; then
          keep_nativefier_cache=true
        else
          rc=$?
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            step=12
            continue
          fi
          keep_nativefier_cache=false
        fi
        step=14
        ;;
      14)
        if prompt_yes_no \
          'Add extra raw Nativefier arguments after --. Enter one token per line in the next step.' \
          'Add extra Nativefier arguments?' \
          'n'; then
          add_extra_nativefier_args=true
          step=15
        else
          rc=$?
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            step=13
            continue
          fi
          add_extra_nativefier_args=false
          extra_nativefier_args=()
          step=16
        fi
        ;;
      15)
        printf '\nEnter one argument per line. For options with values, enter each token on its own line.\n' >&2
        printf 'Press Enter on an empty line to finish.\n' >&2
        extra_nativefier_args=()
        while true; do
          if prompt_text \
            'Add one raw token that will be passed after -- to Nativefier. Press Delete/Backspace on empty input to go back.' \
            'Extra Nativefier arg' \
            ''; then
            rc=0
          else
            rc=$?
          fi
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            step=14
            continue 2
          fi
          [[ ${rc} -eq 0 ]] || exit "${rc}"
          extra_arg="${PROMPT_RESULT}"
          [[ -n "${extra_arg}" ]] || break
          extra_nativefier_args+=("${extra_arg}")
        done
        step=16
        ;;
      16)
        cmd=("bash" "${CLI_SCRIPT}" "--url" "${app_url}")
        if [[ -n "${app_name}" ]]; then
          cmd+=("--name" "${app_name}")
        fi
        if [[ -n "${bundle_id}" ]]; then
          cmd+=("--bundle-id" "${bundle_id}")
        fi
        if [[ -n "${app_version}" ]]; then
          cmd+=("--version" "${app_version}")
        fi
        if [[ -n "${icon_file}" ]]; then
          cmd+=("--icon" "${icon_file}")
        fi
        if [[ -n "${user_agent}" ]]; then
          cmd+=("--user-agent" "${user_agent}")
        fi
        if [[ "${create_dmg}" == true ]]; then
          if [[ -n "${dmg_output}" ]]; then
            cmd+=("--dmg-output" "${dmg_output}")
          fi
        else
          cmd+=("--no-dmg")
        fi
        if [[ ${#internal_domains[@]} -gt 0 ]]; then
          for domain in "${internal_domains[@]}"; do
            cmd+=("--internal-domain" "${domain}")
          done
        fi
        if [[ -n "${internal_urls_regex}" ]]; then
          cmd+=("--internal-urls-regex" "${internal_urls_regex}")
        fi
        if [[ "${generate_pwa}" == true ]]; then
          cmd+=("--generate-pwa")
          if [[ -n "${chrome_profile_directory}" ]]; then
            cmd+=("--chrome-profile-directory" "${chrome_profile_directory}")
          fi
        fi
        if [[ "${keep_build_artifacts}" == true ]]; then
          cmd+=("--keep-build-artifacts")
        fi
        if [[ "${keep_nativefier_cache}" == true ]]; then
          cmd+=("--keep-nativefier-cache")
        fi
        if [[ ${#extra_nativefier_args[@]} -gt 0 ]]; then
          cmd+=("--")
          cmd+=("${extra_nativefier_args[@]}")
        fi

        printf '\nGenerated command:\n%s\n' "$(print_command "${cmd[@]}")"
        step=17
        ;;
      17)
        if prompt_yes_no \
          'Final confirmation. Empty runs the generated command now. Delete/Backspace on empty input returns to the previous question.' \
          'Run this command now?' \
          'y'; then
          exec "${cmd[@]}"
        else
          rc=$?
          if [[ ${rc} -eq ${PROMPT_BACK_CODE} ]]; then
            if [[ "${add_extra_nativefier_args}" == true ]]; then
              step=15
            else
              step=14
            fi
            continue
          fi
          info "Cancelled. Command not executed."
          exit 0
        fi
        ;;
      *)
        die "Unexpected wizard step: ${step}"
        ;;
    esac
  done
}

main "$@"
