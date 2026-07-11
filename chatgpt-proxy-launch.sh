#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
SUPPORT_DIR="${HOME}/Library/Application Support/ChatGPT Proxy"
LEGACY_SUPPORT_DIR="${HOME}/Library/Application Support/Codex Proxy"
CONFIG_FILE="${CHATGPT_PROXY_CONFIG_FILE:-${SUPPORT_DIR}/chatgpt-proxy.conf}"
EXAMPLE_CONFIG_FILE="${CHATGPT_PROXY_EXAMPLE_CONFIG_FILE:-${SCRIPT_DIR}/chatgpt-proxy.conf.example}"
DEBUG_LOG_FILE="${SUPPORT_DIR}/chatgpt-proxy-debug.log"
DEBUG_FLAG_FILE="${SUPPORT_DIR}/diagnostics.enabled"
BRIDGE_PID=""
/bin/mkdir -p "${SUPPORT_DIR}"
if [[ ! -f "${CONFIG_FILE}" && -f "${LEGACY_SUPPORT_DIR}/codex-proxy.conf" ]]; then
  /bin/cp "${LEGACY_SUPPORT_DIR}/codex-proxy.conf" "${CONFIG_FILE}"
fi
DEBUG_OUTPUT="/dev/null"
DEBUG_ENABLED=0
if [[ "${CHATGPT_PROXY_DEBUG:-0}" == "1" || -f "${DEBUG_FLAG_FILE}" ]]; then
  DEBUG_ENABLED=1
  : > "${DEBUG_LOG_FILE}"
  DEBUG_OUTPUT="${DEBUG_LOG_FILE}"
fi

log_debug() {
  [[ "${DEBUG_ENABLED}" == "1" ]] || return 0
  print -r -- "[$(/bin/date '+%F %T')] $*" >> "${DEBUG_LOG_FILE}"
}

log_command() {
  local label="$1"
  shift
  log_debug "${label}: $*"
  "$@" >> "${DEBUG_OUTPUT}" 2>&1 || log_debug "${label} failed with status $?"
}

log_debug "launcher started"

stop_bridge() {
  local pid="${BRIDGE_PID}"
  local attempt
  [[ -n "${pid}" ]] || return 0

  log_debug "stopping bridge ${pid}"
  /bin/kill -TERM "${pid}" >/dev/null 2>&1 || true
  for attempt in {1..20}; do
    /bin/kill -0 "${pid}" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if /bin/kill -0 "${pid}" >/dev/null 2>&1; then
    log_debug "bridge ${pid} did not stop after SIGTERM; sending SIGKILL"
    /bin/kill -KILL "${pid}" >/dev/null 2>&1 || true
  fi
  wait "${pid}" >/dev/null 2>&1 || true
  BRIDGE_PID=""
}

cleanup_launcher() {
  local status=$?
  trap - EXIT
  stop_bridge

  return "${status}"
}

trap cleanup_launcher EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

redact_proxy_url() {
  print -r -- "$1" | /usr/bin/sed -E 's#(socks5h?://)[^/@]+@#\1***@#; s#(https?://)[^/@]+@#\1***@#'
}
DEFAULT_BYPASS_ITEMS=(
  localhost
  127.0.0.1
  ::1
  "*.local"
  local
  10.0.0.0/8
  172.16.0.0/12
  192.168.0.0/16
  169.254.0.0/16
  fc00::/7
  fe80::/10
)

fail() {
  /usr/bin/osascript -e "display dialog \"ChatGPT Proxy failed:\n\n$*\" buttons {\"OK\"} default button \"OK\" with icon stop" >/dev/null 2>&1 || true
  exit 1
}

config_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  print -r -- "\"${value}\""
}

proxy_url_host() {
  local host="$1"
  if [[ "${host}" == \[*\] ]]; then
    print -r -- "${host}"
  elif [[ "${host}" == *:* ]]; then
    print -r -- "[${host}]"
  else
    print -r -- "${host}"
  fi
}

join_by() {
  local delimiter="$1"
  shift
  local joined=""
  local item
  for item in "$@"; do
    if [[ -z "${joined}" ]]; then
      joined="${item}"
    else
      joined="${joined}${delimiter}${item}"
    fi
  done
  print -r -- "${joined}"
}

is_valid_port() {
  local value="$1"
  [[ "${value}" =~ '^[0-9]+$' ]] || return 1
  (( 10#${value} >= 1 && 10#${value} <= 65535 ))
}

bypass_chromium_item() {
  local item="$1"
  if [[ "${item}" == .* ]]; then
    print -r -- "*${item}"
  else
    print -r -- "${item}"
  fi
}

is_resolver_bypass_item() {
  local item="$1"
  [[ "${item}" == *"/"* ]] && return 1
  [[ "${item}" == "<local>" ]] && return 1
  [[ "${item}" == "local" ]] && return 1
  [[ "${item}" == *":"* && "${item}" != *"*"* ]] && return 1
  [[ "${item}" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]] && return 1
  return 0
}

build_bypass_lists() {
  local proxy_items=()
  local chromium_items=()
  local resolver_items=()
  local item chromium_item

  for item in "${BYPASS_ITEMS[@]}"; do
    proxy_items+=("${item}")
    chromium_item="$(bypass_chromium_item "${item}")"
    chromium_items+=("${chromium_item}")
    if is_resolver_bypass_item "${chromium_item}"; then
      resolver_items+=("${chromium_item}")
    fi
  done

  BYPASS_PROXY_LIST="$(join_by "," "${proxy_items[@]}")"
  BYPASS_PROXY_CHROMIUM="$(join_by ";" "${chromium_items[@]}")"
  BYPASS_HOST_RESOLVER=""
  for item in "${resolver_items[@]}"; do
    if [[ -z "${BYPASS_HOST_RESOLVER}" ]]; then
      BYPASS_HOST_RESOLVER="EXCLUDE ${item}"
    else
      BYPASS_HOST_RESOLVER="${BYPASS_HOST_RESOLVER}, EXCLUDE ${item}"
    fi
  done
}

proxy_key() {
  print -r -- "${1:u}"
}

proxy_name() {
  local var="PROXY_$(proxy_key "$1")_NAME"
  print -r -- "${(P)var}"
}

proxy_host() {
  local var="PROXY_$(proxy_key "$1")_HOST"
  print -r -- "${(P)var}"
}

proxy_port() {
  local var="PROXY_$(proxy_key "$1")_PORT"
  print -r -- "${(P)var}"
}

proxy_username() {
  local var="PROXY_$(proxy_key "$1")_USERNAME"
  print -r -- "${(P)var:-}"
}

proxy_password() {
  local var="PROXY_$(proxy_key "$1")_PASSWORD"
  print -r -- "${(P)var:-}"
}

proxy_bridge() {
  local var="PROXY_$(proxy_key "$1")_HTTP_BRIDGE"
  print -r -- "${(P)var:-0}"
}

url_encode_userinfo() {
  emulate -L zsh
  setopt local_options no_multibyte
  local value="$1"
  local result="" char encoded
  local i
  for (( i = 1; i <= ${#value}; i++ )); do
    char="${value[i]}"
    if [[ "${char}" == [A-Za-z0-9._~-] ]]; then
      result+="${char}"
    else
      printf -v encoded '%%%02X' "'${char}"
      result+="${encoded}"
    fi
  done
  print -r -- "${result}"
}

proxy_userinfo() {
  local username password
  username="$(proxy_username "$1")"
  password="$(proxy_password "$1")"
  if [[ -z "${username}" && -z "${password}" ]]; then
    print -r -- ""
    return
  fi
  print -r -- "$(url_encode_userinfo "${username}"):$(url_encode_userinfo "${password}")@"
}

proxy_label() {
  local id="$1"
  print -r -- "$(proxy_name "${id}") ($(proxy_host "${id}"):$(proxy_port "${id}"))"
}

proxy_exists() {
  local id="$1" item
  for item in "${PROXY_IDS[@]}"; do
    [[ "${item}" == "${id}" ]] && return 0
  done
  return 1
}

proxy_id_for_label() {
  local label="$1" item
  for item in "${PROXY_IDS[@]}"; do
    if [[ "$(proxy_label "${item}")" == "${label}" ]]; then
      print -r -- "${item}"
      return 0
    fi
  done
  return 1
}

proxy_name_exists_except() {
  local name="$1"
  local except_id="$2"
  local item
  for item in "${PROXY_IDS[@]}"; do
    [[ "${item}" == "${except_id}" ]] && continue
    [[ "$(proxy_name "${item}")" == "${name}" ]] && return 0
  done
  return 1
}

generate_proxy_id() {
  local name="$1"
  local base id suffix
  base="${name:l}"
  base="${base//[^a-z0-9]/_}"
  base="${base##_}"
  base="${base%%_}"
  [[ -z "${base}" ]] && base="proxy"
  id="${base}"
  suffix=2
  while proxy_exists "${id}"; do
    id="${base}_${suffix}"
    (( suffix++ ))
  done
  print -r -- "${id}"
}

ensure_proxy_config() {
  if ! typeset -p PROXY_IDS >/dev/null 2>&1; then
    PROXY_IDS=(local remote)
    PROXY_LOCAL_NAME="Local SOCKS"
    PROXY_LOCAL_HOST="${LOCAL_PROXY_HOST:-127.0.0.1}"
    PROXY_LOCAL_PORT="${LOCAL_PROXY_PORT:-1080}"
    PROXY_LOCAL_USERNAME=""
    PROXY_LOCAL_PASSWORD=""
    PROXY_LOCAL_HTTP_BRIDGE="1"
    PROXY_REMOTE_NAME="Remote SOCKS"
    PROXY_REMOTE_HOST="${REMOTE_PROXY_HOST:-proxy.example.com}"
    PROXY_REMOTE_PORT="${REMOTE_PROXY_PORT:-1080}"
    PROXY_REMOTE_USERNAME=""
    PROXY_REMOTE_PASSWORD=""
    PROXY_REMOTE_HTTP_BRIDGE="1"
  fi

  if (( ${#PROXY_IDS[@]} == 0 )); then
    fail "No proxies are configured."
  fi

  if ! proxy_exists "${ACTIVE_PROXY:-}"; then
    ACTIVE_PROXY="${PROXY_IDS[1]}"
  fi

  if ! typeset -p BYPASS_ITEMS >/dev/null 2>&1; then
    if typeset -p BYPASS_EXTRA_ITEMS >/dev/null 2>&1; then
      BYPASS_ITEMS=("${DEFAULT_BYPASS_ITEMS[@]}" "${BYPASS_EXTRA_ITEMS[@]}")
    else
      BYPASS_ITEMS=("${DEFAULT_BYPASS_ITEMS[@]}")
    fi
  fi
}

save_config() {
  local id key value bypass_items=()
  {
    print -r -- '# Active proxy id. Edit through ChatGPT Proxy, or update this file manually.'
    print -r -- "ACTIVE_PROXY=$(config_quote "${ACTIVE_PROXY}")"
    print -r -- ''
    print -r -- '# Configured SOCKS5 proxies.'
    print -r -- "PROXY_IDS=(${PROXY_IDS[@]})"
    for id in "${PROXY_IDS[@]}"; do
      key="$(proxy_key "${id}")"
      value="$(proxy_name "${id}")"
      print -r -- "PROXY_${key}_NAME=$(config_quote "${value}")"
      value="$(proxy_host "${id}")"
      print -r -- "PROXY_${key}_HOST=$(config_quote "${value}")"
      value="$(proxy_port "${id}")"
      print -r -- "PROXY_${key}_PORT=$(config_quote "${value}")"
      value="$(proxy_username "${id}")"
      print -r -- "PROXY_${key}_USERNAME=$(config_quote "${value}")"
      value="$(proxy_password "${id}")"
      print -r -- "PROXY_${key}_PASSWORD=$(config_quote "${value}")"
      value="$(proxy_bridge "${id}")"
      print -r -- "PROXY_${key}_HTTP_BRIDGE=$(config_quote "${value}")"
      print -r -- ''
    done

    print -r -- '# Local HTTP CONNECT bridge used when a proxy enables HTTP bridge mode.'
    print -r -- "HTTP_BRIDGE_HOST=$(config_quote "${HTTP_BRIDGE_HOST:-127.0.0.1}")"
    print -r -- "HTTP_BRIDGE_PORT=$(config_quote "${HTTP_BRIDGE_PORT:-28083}")"
    print -r -- ''
    print -r -- '# Hosts, domains, IPs, or CIDRs that should connect directly.'
    print -r -- '# This starts with local/LAN defaults, but every item is editable in the launcher.'
    for value in "${BYPASS_ITEMS[@]}"; do
      bypass_items+=("$(config_quote "${value}")")
    done
    print -r -- "BYPASS_ITEMS=(${bypass_items[@]})"
  } > "${CONFIG_FILE}"
}

choose_from_list() {
  local title="$1"
  local prompt="$2"
  shift 2
  /usr/bin/osascript - "${title}" "${prompt}" "$@" <<'OSA'
on run argv
  set dialogTitle to item 1 of argv
  set dialogPrompt to item 2 of argv
  set choices to items 3 thru -1 of argv
  set picked to choose from list choices with title dialogTitle with prompt dialogPrompt OK button name "OK" cancel button name "Cancel"
  if picked is false then error number -128
  item 1 of picked
end run
OSA
}

choose_from_list_default() {
  local title="$1"
  local prompt="$2"
  local default_value="$3"
  shift 3
  /usr/bin/osascript - "${title}" "${prompt}" "${default_value}" "$@" <<'OSA'
on run argv
  set dialogTitle to item 1 of argv
  set dialogPrompt to item 2 of argv
  set defaultChoice to item 3 of argv
  set choices to items 4 thru -1 of argv
  set picked to choose from list choices with title dialogTitle with prompt dialogPrompt default items {defaultChoice} OK button name "OK" cancel button name "Cancel"
  if picked is false then error number -128
  item 1 of picked
end run
OSA
}

prompt_text() {
  local title="$1"
  local prompt="$2"
  local default_value="${3:-}"
  /usr/bin/osascript - "${title}" "${prompt}" "${default_value}" <<'OSA'
on run argv
  set dialogTitle to item 1 of argv
  set dialogPrompt to item 2 of argv
  set defaultValue to item 3 of argv
  text returned of (display dialog dialogPrompt default answer defaultValue buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with title dialogTitle)
end run
OSA
}

confirm_dialog() {
  local title="$1"
  local message="$2"
  /usr/bin/osascript - "${title}" "${message}" <<'OSA'
on run argv
  display dialog (item 2 of argv) buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with title (item 1 of argv)
end run
OSA
}

add_proxy() {
  local id name host port username password bridge_button key

  name="$(prompt_text "Add Proxy" "Proxy name. Names must be unique." "")" || return 0
  if [[ -z "${name}" ]]; then
    return 0
  fi
  if proxy_name_exists_except "${name}" ""; then
    fail "Proxy name already exists: ${name}"
  fi
  id="$(generate_proxy_id "${name}")"
  host="$(prompt_text "Add Proxy" "SOCKS5 host for ${name}." "")" || return 0
  port="$(prompt_text "Add Proxy" "SOCKS5 port for ${name}." "1080")" || return 0
  if ! is_valid_port "${port}"; then
    fail "Invalid proxy port: ${port}"
  fi
  username="$(prompt_text "Add Proxy" "Optional SOCKS5 username for ${name}. Leave empty if not required." "")" || return 0
  password="$(prompt_text "Add Proxy" "Optional SOCKS5 password for ${name}. Leave empty if not required." "")" || return 0

  bridge_button="$(
    /usr/bin/osascript - "${name}" <<'OSA'
on run argv
  button returned of (display dialog "Use local HTTP bridge for " & (item 1 of argv) & "?" & return & return & "Enable this if plugin marketplace or app-server requests do not work through SOCKS5 env vars." buttons {"No", "Yes"} default button "No" with title "Add Proxy")
end run
OSA
  )" || return 0

  PROXY_IDS+=("${id}")
  key="$(proxy_key "${id}")"
  typeset -g "PROXY_${key}_NAME=${name}"
  typeset -g "PROXY_${key}_HOST=${host}"
  typeset -g "PROXY_${key}_PORT=${port}"
  typeset -g "PROXY_${key}_USERNAME=${username}"
  typeset -g "PROXY_${key}_PASSWORD=${password}"
  if [[ "${bridge_button}" == "Yes" ]]; then
    typeset -g "PROXY_${key}_HTTP_BRIDGE=1"
  else
    typeset -g "PROXY_${key}_HTTP_BRIDGE=0"
  fi
  ACTIVE_PROXY="${id}"
  save_config
}

edit_proxy() {
  local labels=() label id key name host port username password bridge_button item

  for item in "${PROXY_IDS[@]}"; do
    labels+=("$(proxy_label "${item}")")
  done
  label="$(choose_from_list "Edit Proxy" "Choose a proxy to edit." "${labels[@]}")" || return 0
  id="$(proxy_id_for_label "${label}")" || return 0
  key="$(proxy_key "${id}")"

  name="$(prompt_text "Edit Proxy" "Proxy name. Names must be unique." "$(proxy_name "${id}")")" || return 0
  if [[ -z "${name}" ]]; then
    return 0
  fi
  if proxy_name_exists_except "${name}" "${id}"; then
    fail "Proxy name already exists: ${name}"
  fi
  host="$(prompt_text "Edit Proxy" "SOCKS5 host for ${name}." "$(proxy_host "${id}")")" || return 0
  port="$(prompt_text "Edit Proxy" "SOCKS5 port for ${name}." "$(proxy_port "${id}")")" || return 0
  if ! is_valid_port "${port}"; then
    fail "Invalid proxy port: ${port}"
  fi
  username="$(prompt_text "Edit Proxy" "Optional SOCKS5 username for ${name}. Leave empty if not required." "$(proxy_username "${id}")")" || return 0
  password="$(prompt_text "Edit Proxy" "Optional SOCKS5 password for ${name}. Leave empty if not required." "$(proxy_password "${id}")")" || return 0

  bridge_button="$(
    /usr/bin/osascript - "${name}" "$(proxy_bridge "${id}")" <<'OSA'
on run argv
  set proxyName to item 1 of argv
  set bridgeEnabled to item 2 of argv
  if bridgeEnabled is "1" then
    set defaultButtonName to "Yes"
  else
    set defaultButtonName to "No"
  end if
  button returned of (display dialog "Use local HTTP bridge for " & proxyName & "?" buttons {"No", "Yes"} default button defaultButtonName with title "Edit Proxy")
end run
OSA
  )" || return 0

  typeset -g "PROXY_${key}_NAME=${name}"
  typeset -g "PROXY_${key}_HOST=${host}"
  typeset -g "PROXY_${key}_PORT=${port}"
  typeset -g "PROXY_${key}_USERNAME=${username}"
  typeset -g "PROXY_${key}_PASSWORD=${password}"
  if [[ "${bridge_button}" == "Yes" ]]; then
    typeset -g "PROXY_${key}_HTTP_BRIDGE=1"
  else
    typeset -g "PROXY_${key}_HTTP_BRIDGE=0"
  fi
  save_config
}

delete_proxy() {
  local labels=() label id remaining=() item

  if (( ${#PROXY_IDS[@]} <= 1 )); then
    /usr/bin/osascript -e 'display dialog "At least one proxy must remain." buttons {"OK"} default button "OK" with title "Delete Proxy"' >/dev/null 2>&1 || true
    return 0
  fi

  for item in "${PROXY_IDS[@]}"; do
    labels+=("$(proxy_label "${item}")")
  done
  label="$(choose_from_list "Delete Proxy" "Choose a proxy to delete." "${labels[@]}")" || return 0
  id="$(proxy_id_for_label "${label}")" || return 0
  confirm_dialog "Delete Proxy" "Delete $(proxy_label "${id}")?" || return 0

  for item in "${PROXY_IDS[@]}"; do
    [[ "${item}" != "${id}" ]] && remaining+=("${item}")
  done
  PROXY_IDS=("${remaining[@]}")
  if [[ "${ACTIVE_PROXY}" == "${id}" ]]; then
    ACTIVE_PROXY="${PROXY_IDS[1]}"
  fi
  save_config
}

manage_proxies() {
  local action
  while true; do
    action="$(choose_from_list "Proxy Manager" "Manage ChatGPT proxy configurations." "Add Proxy" "Edit Proxy" "Delete Proxy" "Back")" || return 0
    case "${action}" in
      "Add Proxy")
        add_proxy
        ;;
      "Edit Proxy")
        edit_proxy
        ;;
      "Delete Proxy")
        delete_proxy
        ;;
      "Back")
        return 0
        ;;
    esac
  done
}

add_bypass_item() {
  local item
  item="$(prompt_text "Add Bypass" "Host, domain, wildcard domain, IP, or CIDR to connect directly." "")" || return 0
  item="${item#"${item%%[![:space:]]*}"}"
  item="${item%"${item##*[![:space:]]}"}"
  if [[ -z "${item}" ]]; then
    return 0
  fi
  BYPASS_ITEMS+=("${item}")
  save_config
}

delete_bypass_item() {
  local item picked remaining=()

  if (( ${#BYPASS_ITEMS[@]} == 0 )); then
    /usr/bin/osascript -e 'display dialog "No bypass items to delete." buttons {"OK"} default button "OK" with title "Delete Bypass"' >/dev/null 2>&1 || true
    return 0
  fi

  picked="$(choose_from_list "Delete Bypass" "Choose a bypass item to delete." "${BYPASS_ITEMS[@]}")" || return 0
  confirm_dialog "Delete Bypass" "Delete ${picked} from the bypass list?" || return 0
  for item in "${BYPASS_ITEMS[@]}"; do
    [[ "${item}" != "${picked}" ]] && remaining+=("${item}")
  done
  BYPASS_ITEMS=("${remaining[@]}")
  save_config
}

reset_bypass_items() {
  confirm_dialog "Reset Bypass List" "Restore the default local and private-network bypass list?" || return 0
  BYPASS_ITEMS=("${DEFAULT_BYPASS_ITEMS[@]}")
  save_config
}

manage_bypass_list() {
  local action
  while true; do
    action="$(choose_from_list "Bypass Manager" "Manage direct-connect hosts, domains, IPs, and CIDRs." "Add Bypass" "Delete Bypass" "Reset to Defaults" "Back")" || return 0
    case "${action}" in
      "Add Bypass")
        add_bypass_item
        ;;
      "Delete Bypass")
        delete_bypass_item
        ;;
      "Reset to Defaults")
        reset_bypass_items
        ;;
      "Back")
        return 0
        ;;
    esac
  done
}

choose_active_proxy() {
  local labels=() label item
  for item in "${PROXY_IDS[@]}"; do
    labels+=("$(proxy_label "${item}")")
  done
  label="$(choose_from_list "Choose Proxy" "Choose a proxy for this ChatGPT launch." "${labels[@]}")" || return 0
  ACTIVE_PROXY="$(proxy_id_for_label "${label}")"
  save_config
}

select_active_proxy() {
  local labels=() action current_label item

  while true; do
    labels=()
    for item in "${PROXY_IDS[@]}"; do
      labels+=("$(proxy_label "${item}")")
    done
    current_label="$(proxy_label "${ACTIVE_PROXY}")"
    action="$(choose_from_list_default "ChatGPT Proxy" "Select a proxy, then click OK to launch ChatGPT." "${current_label}" "${labels[@]}" "Manage Proxies..." "Manage Bypass List...")" || exit 0
    case "${action}" in
      "Manage Proxies...")
        manage_proxies
        ;;
      "Manage Bypass List...")
        manage_bypass_list
        ;;
      *)
        ACTIVE_PROXY="$(proxy_id_for_label "${action}")"
        save_config
        return 0
        ;;
    esac
  done
}

if [[ ! -f "${CONFIG_FILE}" ]]; then
  if [[ -f "${EXAMPLE_CONFIG_FILE}" ]]; then
    cp "${EXAMPLE_CONFIG_FILE}" "${CONFIG_FILE}"
  else
    fail "Missing config file: ${CONFIG_FILE}"
  fi
fi

source "${CONFIG_FILE}"
ensure_proxy_config
log_debug "config loaded from ${CONFIG_FILE}"
log_debug "active proxy id: ${ACTIVE_PROXY}"

if [[ "${CHATGPT_PROXY_SKIP_UI:-0}" != "1" ]]; then
  select_active_proxy
  log_debug "active proxy after UI: ${ACTIVE_PROXY}"
fi

PROXY_HOST="$(proxy_host "${ACTIVE_PROXY}")"
PROXY_PORT="$(proxy_port "${ACTIVE_PROXY}")"
if ! is_valid_port "${PROXY_PORT}"; then
  fail "Invalid SOCKS5 proxy port: ${PROXY_PORT}. Use a value from 1 to 65535."
fi
PROXY_URL_HOST="$(proxy_url_host "${PROXY_HOST}")"
PROXY_USERINFO="$(proxy_userinfo "${ACTIVE_PROXY}")"
PROXY_ENV="socks5h://${PROXY_USERINFO}${PROXY_URL_HOST}:${PROXY_PORT}"
PROXY_CHROMIUM="socks5://${PROXY_USERINFO}${PROXY_URL_HOST}:${PROXY_PORT}"
CHROMIUM_PROXY="${PROXY_CHROMIUM}"
build_bypass_lists
NO_PROXY_LIST="${BYPASS_PROXY_LIST},${PROXY_HOST}"
HOST_RESOLVER_RULES="${CHROMIUM_HOST_RESOLVER_RULES:-}"
log_debug "proxy host: ${PROXY_HOST}"
log_debug "proxy port: ${PROXY_PORT}"
if [[ -n "$(proxy_username "${ACTIVE_PROXY}")" || -n "$(proxy_password "${ACTIVE_PROXY}")" ]]; then
  log_debug "proxy authentication: enabled"
else
  log_debug "proxy authentication: disabled"
fi
log_debug "proxy bridge enabled: $(proxy_bridge "${ACTIVE_PROXY}")"
log_debug "initial env proxy scheme: socks5h"
log_debug "initial chromium proxy scheme: socks5"
log_debug "no_proxy: ${NO_PROXY_LIST}"
log_debug "host resolver rules: ${HOST_RESOLVER_RULES}"

if [[ "${PROXY_HOST}" != "127.0.0.1" && "${PROXY_HOST}" != "localhost" ]]; then
  log_debug "checking DNS for ${PROXY_HOST}"
  if ! /usr/bin/dscacheutil -q host -a name "${PROXY_HOST}" >/dev/null 2>&1 && [[ "${PROXY_HOST}" != *":"* ]]; then
    log_debug "DNS check failed for ${PROXY_HOST}"
    fail "Cannot resolve ${PROXY_HOST}. Check DNS, or edit chatgpt-proxy.conf and set PROXY_$(proxy_key "${ACTIVE_PROXY}")_HOST to an IP address directly."
  fi
fi
log_debug "checking TCP connection to ${PROXY_HOST}:${PROXY_PORT}"
if ! /usr/bin/nc -z -w 5 "${PROXY_HOST}" "${PROXY_PORT}" >/dev/null 2>&1; then
  log_debug "TCP check failed for ${PROXY_HOST}:${PROXY_PORT}"
  fail "Cannot connect to SOCKS5 proxy ${PROXY_HOST}:${PROXY_PORT}. Choose another proxy or check that it is reachable from this Mac."
fi
log_debug "TCP check passed for ${PROXY_HOST}:${PROXY_PORT}"

chatgpt_process_pids() {
  local pid command
  for pid in "${(@f)$("/usr/bin/pgrep" -f /Applications/ChatGPT.app/Contents 2>/dev/null || true)}"; do
    [[ -n "${pid}" ]] || continue
    command="$(/bin/ps -p "${pid}" -o command= 2>/dev/null || true)"
    [[ -n "${command}" ]] || continue
    [[ "${command}" != *"chatgpt-socks-http-bridge"* ]] || continue
    print -r -- "${pid}"
  done
}

chatgpt_main_pids() {
  /bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk \
    '$2 == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" { print $1 }'
}

chatgpt_residual_pids() {
  /bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk \
    'index($2, "/Applications/ChatGPT.app/Contents/") == 1 { print $1 }'
}

cleanup_orphaned_chatgpt_processes() {
  local pids=() remaining=()
  local pid attempt residual_output main_output

  main_output="$(chatgpt_main_pids)"
  if [[ -n "${main_output}" ]]; then
    if [[ "${CHATGPT_PROXY_SKIP_UI:-0}" != "1" ]]; then
      fail "ChatGPT is still running. Quit it completely, then launch ChatGPT Proxy again."
    fi

    pids=("${(@f)main_output}")
    log_debug "ChatGPT main process survived the UI quit request: ${pids[*]}"
    /bin/kill -TERM "${pids[@]}" >/dev/null 2>&1 || true
    for attempt in {1..30}; do
      [[ -z "$(chatgpt_main_pids)" ]] && break
      sleep 0.1
    done
    if [[ -n "$(chatgpt_main_pids)" ]]; then
      log_debug "forcing surviving ChatGPT main process to stop: ${pids[*]}"
      /bin/kill -KILL "${pids[@]}" >/dev/null 2>&1 || true
      sleep 0.2
    fi
    if [[ -n "$(chatgpt_main_pids)" ]]; then
      fail "ChatGPT is still running after the quit request. Force Quit it, then launch ChatGPT Proxy again."
    fi
  fi

  residual_output="$(chatgpt_residual_pids)"
  [[ -n "${residual_output}" ]] || return 0
  pids=("${(@f)residual_output}")
  log_debug "stopping orphaned ChatGPT processes: ${pids[*]}"
  /bin/kill -TERM "${pids[@]}" >/dev/null 2>&1 || true

  for attempt in {1..30}; do
    remaining=()
    for pid in "${pids[@]}"; do
      /bin/kill -0 "${pid}" >/dev/null 2>&1 && remaining+=("${pid}")
    done
    (( ${#remaining[@]} == 0 )) && return 0
    sleep 0.1
  done

  log_debug "forcing orphaned ChatGPT processes to stop: ${remaining[*]}"
  /bin/kill -KILL "${remaining[@]}" >/dev/null 2>&1 || true
  sleep 0.1
  if [[ -n "$(chatgpt_residual_pids)" ]]; then
    fail "Some orphaned ChatGPT helper processes could not be stopped. Log out of macOS and try again."
  fi
}

cleanup_orphaned_chatgpt_processes

if [[ "$(proxy_bridge "${ACTIVE_PROXY}")" == "1" ]]; then
  BRIDGE_HOST="${HTTP_BRIDGE_HOST:-127.0.0.1}"
  BRIDGE_PORT="${HTTP_BRIDGE_PORT:-28083}"
  case "${BRIDGE_HOST}" in
    127.0.0.1|localhost|::1) ;;
    *) fail "Bridge host must be a loopback address: 127.0.0.1, localhost, or ::1." ;;
  esac
  if ! is_valid_port "${BRIDGE_PORT}"; then
    fail "Invalid local HTTP bridge port: ${BRIDGE_PORT}. Use a value from 1 to 65535."
  fi
  if /usr/bin/nc -z "${BRIDGE_HOST}" "${BRIDGE_PORT}" >/dev/null 2>&1; then
    fail "Local HTTP bridge port ${BRIDGE_HOST}:${BRIDGE_PORT} is already in use. Quit the existing ChatGPT Proxy session or choose another port."
  fi
  BRIDGE_PROXY_ENV="http://$(proxy_url_host "${BRIDGE_HOST}"):${BRIDGE_PORT}"
  log_debug "bridge proxy env: ${BRIDGE_PROXY_ENV}"
  BRIDGE_EXECUTABLE="${SCRIPT_DIR}/chatgpt-socks-http-bridge"
  if [[ ! -x "${BRIDGE_EXECUTABLE}" ]]; then
    fail "Cannot find native HTTP bridge: ${BRIDGE_EXECUTABLE}"
  fi
  log_debug "bridge command: ${BRIDGE_EXECUTABLE}"

  BRIDGE_LISTEN_HOST="${BRIDGE_HOST}" \
  BRIDGE_LISTEN_PORT="${BRIDGE_PORT}" \
  UPSTREAM_SOCKS_HOST="${PROXY_HOST}" \
  UPSTREAM_SOCKS_PORT="${PROXY_PORT}" \
  UPSTREAM_SOCKS_USERNAME="$(proxy_username "${ACTIVE_PROXY}")" \
  UPSTREAM_SOCKS_PASSWORD="$(proxy_password "${ACTIVE_PROXY}")" \
  BRIDGE_DEBUG="${DEBUG_ENABLED}" \
    "${BRIDGE_EXECUTABLE}" >> "${DEBUG_OUTPUT}" 2>&1 &
  BRIDGE_PID=$!
  log_debug "bridge pid: ${BRIDGE_PID}"

  for _ in {1..20}; do
    if /bin/kill -0 "${BRIDGE_PID}" >/dev/null 2>&1 && \
       /usr/bin/nc -z "${BRIDGE_HOST}" "${BRIDGE_PORT}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if ! /bin/kill -0 "${BRIDGE_PID}" >/dev/null 2>&1 || \
     ! /usr/bin/nc -z "${BRIDGE_HOST}" "${BRIDGE_PORT}" >/dev/null 2>&1; then
    log_debug "bridge did not start on ${BRIDGE_HOST}:${BRIDGE_PORT}"
    fail "Local HTTP bridge did not start on ${BRIDGE_HOST}:${BRIDGE_PORT}."
  fi
  log_debug "bridge is listening on ${BRIDGE_HOST}:${BRIDGE_PORT}"

  # Listening alone does not prove that macOS allows this app to reach a LAN
  # SOCKS server. Exercise one real CONNECT before opening ChatGPT so a denied
  # Local Network permission fails clearly instead of producing a broken UI.
  BRIDGE_PREFLIGHT_URL="${CHATGPT_PROXY_PREFLIGHT_URL:-https://api.openai.com/}"
  log_debug "checking bridge upstream connectivity"
  if ! /usr/bin/curl \
      --silent \
      --show-error \
      --output /dev/null \
      --connect-timeout 8 \
      --max-time 15 \
      --noproxy "" \
      --proxy "${BRIDGE_PROXY_ENV}" \
      "${BRIDGE_PREFLIGHT_URL}" >> "${DEBUG_OUTPUT}" 2>&1; then
    log_debug "bridge upstream connectivity check failed"
    fail "The local HTTP bridge started, but SOCKS5 CONNECT through ${PROXY_HOST}:${PROXY_PORT} failed. Check local-network permission for ChatGPT Proxy when this proxy is on your LAN, then verify the SOCKS5 service and its upstream route."
  fi
  log_debug "bridge upstream connectivity check passed"

  PROXY_ENV="${BRIDGE_PROXY_ENV}"
  log_debug "final env proxy after bridge: ${PROXY_ENV}"
  log_debug "final chromium proxy remains: ${CHROMIUM_PROXY}"
fi

export ALL_PROXY="${PROXY_ENV}"
export HTTP_PROXY="${PROXY_ENV}"
export HTTPS_PROXY="${PROXY_ENV}"
export all_proxy="${PROXY_ENV}"
export http_proxy="${PROXY_ENV}"
export https_proxy="${PROXY_ENV}"
export NO_PROXY="${NO_PROXY_LIST}"
export no_proxy="${NO_PROXY_LIST}"

if [[ ! -x /Applications/ChatGPT.app/Contents/MacOS/ChatGPT ]]; then
  fail "Cannot find executable: /Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
fi
CHATGPT_EXECUTABLE="/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"

CHATGPT_ARGS=(
  "--proxy-server=${CHROMIUM_PROXY}"
  "--proxy-bypass-list=${BYPASS_PROXY_CHROMIUM};${PROXY_HOST}"
)
if [[ -n "${HOST_RESOLVER_RULES}" ]]; then
  CHATGPT_ARGS+=("--host-resolver-rules=${HOST_RESOLVER_RULES}")
fi

log_debug "launch args: $(redact_proxy_url "${CHATGPT_ARGS[*]}")"
"${CHATGPT_EXECUTABLE}" "${CHATGPT_ARGS[@]}" >> "${DEBUG_OUTPUT}" 2>&1 &
CHATGPT_MAIN_PID=$!
OPEN_STATUS=0
log_debug "ChatGPT main pid: ${CHATGPT_MAIN_PID}"

if [[ -n "${BRIDGE_PID}" ]] && ! /bin/kill -0 "${BRIDGE_PID}" >/dev/null 2>&1; then
  /bin/kill -TERM "${CHATGPT_MAIN_PID}" >/dev/null 2>&1 || true
  fail "The local HTTP bridge exited during ChatGPT startup. ChatGPT was stopped and no temporary proxy environment was left active."
fi

if ! /bin/kill -0 "${CHATGPT_MAIN_PID}" >/dev/null 2>&1; then
  wait "${CHATGPT_MAIN_PID}" >/dev/null 2>&1 || true
  fail "ChatGPT exited before startup completed. The local HTTP bridge and temporary proxy environment were cleaned up."
fi

log_debug "ChatGPT pids after launch: $(join_by " " "${(@f)$(chatgpt_process_pids)}")"
for pid in "${(@f)$(chatgpt_process_pids)}"; do
  log_command "ChatGPT process ${pid}" /bin/ps -p "${pid}" -o pid=,comm=
done

if [[ "${OPEN_STATUS}" -eq 0 ]]; then
  log_debug "waiting for ChatGPT main process ${CHATGPT_MAIN_PID}"
  wait "${CHATGPT_MAIN_PID}" || OPEN_STATUS=$?
  log_debug "ChatGPT main process exited with status ${OPEN_STATUS}"
fi

exit "${OPEN_STATUS}"
