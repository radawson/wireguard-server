#!/bin/bash
# WireGuard client/peer handler
# (C) 2021-2026 Richard Dawson
VERSION="2.13.0"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="/usr/local/share/wireguard/lib/common.sh"
if [[ ! -f "${LIB_FILE}" ]]; then
  LIB_FILE="${SCRIPT_DIR}/../lib/common.sh"
fi
if [[ ! -f "${LIB_FILE}" ]]; then
  printf "Missing required library file. Expected /usr/local/share/wireguard/lib/common.sh or ../lib/common.sh\n" >&2
  exit 1
fi
source "${LIB_FILE}"

DISPLAY_QR="false"
FORCE="false"
OVERWRITE="false"
DELETE_FILES="false"
VERBOSE="false"

PEER_IP=""
PEER_NAME=""
SERVER_IP=""
SERVER_PORT=""
MA_MODE="false"
CLIENT_ALLOWED_IPS=""
INSTALL_DIRECTORY="${WG_DIR}"
SERVER_PRIVATE_FILE="server_key.pri"
SERVER_PUBLIC_FILE="server_key.pub"
ADAPTER=""
BRANCH="main"
FORCE_CONF="false"
VERSION_CONF=""
CLI_SERVER_IP=""
CLI_SERVER_PORT=""

SERVER_CONF_FILE=""
SERVER_WG_CONF_FILE=""
PEER_LIST_FILE=""
LAST_IP_FILE=""
CLIENTS_DIR=""
SERVER_DIR=""
CLIENT_TEMPLATE=""
SERVER_PUB_FILE=""
INSTALL_CLIENT_SCRIPT=""

usage() {
  cat <<EOF >&2
Usage: ${0} [options] <command> [peer_name|peer_public_key]
Manage WireGuard clients/peers.

Commands:
  add <peer_name>      Create client config and register peer
  list                 List known peers
  remove <target>      Remove peer by name or public key
  show [peer_name]     Show one client config (or all peers if omitted)
  update <peer_name>   Recreate keys/config for existing peer (keeps IP)
  status               Show wg interface status
  help                 Show this help

Options:
  -f              Force run as root.
  -h              Show help.
  -i IP_ADDRESS   Set/override peer IP (for add/update).
  -o              Overwrite existing client.
  -p SERVER_PORT  Set server listen port.
  -q              Display QR code on screen.
  -s SERVER_IP    Set server public endpoint IP.
  -v              Verbose output.
  -D              Delete client files on remove.
EOF
}

refresh_paths() {
  SERVER_CONF_FILE="${WG_CONF}"
  SERVER_WG_CONF_FILE="${WG_DIR}/wg0.conf"
  PEER_LIST_FILE="${WG_DIR}/peer_list.txt"
  LAST_IP_FILE="${WG_DIR}/last_ip.txt"
  CLIENTS_DIR="${WG_DIR}/clients"
  SERVER_DIR="${WG_DIR}/server"
  CLIENT_TEMPLATE="${WG_DIR}/config/wg0-client.example.conf"
  SERVER_PUB_FILE="${SERVER_DIR}/${SERVER_PUBLIC_FILE}"
  INSTALL_CLIENT_SCRIPT="${WG_SHARE}/install-client.sh"
}

load_server_conf() {
  local conf_tmp
  refresh_paths
  if sudo test -f "${SERVER_CONF_FILE}"; then
    conf_tmp="$(mktemp)"
    sudo cat "${SERVER_CONF_FILE}" >"${conf_tmp}"
    # shellcheck disable=SC1090
    source "${conf_tmp}"
    rm -f "${conf_tmp}"
  fi

  SERVER_IP="${SERVER_IP:-$(ip -o route get to 1 | awk '{for (i=1; i<=NF; i++) if ($i=="src") print $(i+1)}' | head -n1)}"
  if [[ -z "${SERVER_PORT:-}" ]] && sudo test -f "${SERVER_WG_CONF_FILE}"; then
    SERVER_PORT="$(sudo awk -F'=' '/^ListenPort/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${SERVER_WG_CONF_FILE}")"
  fi
  SERVER_PORT="${SERVER_PORT:-51820}"
  MA_MODE="${MA_MODE:-false}"
  CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-}"
  if [[ -n "${CLI_SERVER_IP}" ]]; then
    SERVER_IP="${CLI_SERVER_IP}"
  fi
  if [[ -n "${CLI_SERVER_PORT}" ]]; then
    SERVER_PORT="${CLI_SERVER_PORT}"
  fi
  refresh_paths
}

ensure_layout() {
  sudo mkdir -p "${CLIENTS_DIR}" "${SERVER_DIR}"
  sudo touch "${PEER_LIST_FILE}"
}

allowed_ips_for_peer() {
  local peer_ip="$1"
  if [[ "${MA_MODE}" == "true" ]]; then
    printf "0.0.0.0/0\n"
  elif [[ -n "${CLIENT_ALLOWED_IPS}" ]]; then
    printf "%s\n" "${CLIENT_ALLOWED_IPS}"
  else
    printf "%s/24\n" "$(awk -F. '{print $1"."$2"."$3".0"}' <<<"${peer_ip}")"
  fi
}

next_peer_ip() {
  local base_ip
  local base
  local last_octet
  local candidate

  base_ip="${SERVER_IP:-10.100.200.1}"
  base="$(awk -F. '{print $1"."$2"."$3}' <<<"${base_ip}")"
  last_octet="$(sudo awk -F. '{print $4}' "${LAST_IP_FILE}" 2>/dev/null || true)"
  if [[ -z "${last_octet}" || ! "${last_octet}" =~ ^[0-9]+$ ]]; then
    last_octet="$(awk -F. '{print $4}' <<<"${base_ip}")"
  fi
  candidate=$((last_octet + 1))

  while [[ "${candidate}" -le 254 ]]; do
    if ! grep -q "^${base}\.${candidate}," "${PEER_LIST_FILE}" 2>/dev/null; then
      printf "%s.%s\n" "${base}" "${candidate}"
      return 0
    fi
    candidate=$((candidate + 1))
  done

  die "No free IP addresses left in ${base}.0/24"
}

set_last_ip() {
  local ip="$1"
  printf "%s\n" "${ip}" | sudo tee "${LAST_IP_FILE}" >/dev/null
}

resolve_peer() {
  local target="$1"
  local mode

  RESOLVED_PEER_IP=""
  RESOLVED_PEER_NAME=""
  RESOLVED_PEER_PUB=""

  if [[ "${target}" == *"=" ]]; then
    mode="pub"
  else
    mode="name"
  fi

  while IFS=, read -r ip name pub; do
    [[ -z "${ip}" ]] && continue
    if [[ "${mode}" == "pub" && "${pub}" == "${target}" ]]; then
      RESOLVED_PEER_IP="${ip}"
      RESOLVED_PEER_NAME="${name}"
      RESOLVED_PEER_PUB="${pub}"
      return 0
    fi
    if [[ "${mode}" == "name" && "${name}" == "${target}" ]]; then
      RESOLVED_PEER_IP="${ip}"
      RESOLVED_PEER_NAME="${name}"
      RESOLVED_PEER_PUB="${pub}"
      return 0
    fi
  done < <(sudo cat "${PEER_LIST_FILE}" 2>/dev/null || true)

  if [[ "${mode}" == "name" ]] && sudo test -f "${CLIENTS_DIR}/${target}/${target}.pub"; then
    RESOLVED_PEER_NAME="${target}"
    RESOLVED_PEER_PUB="$(sudo cat "${CLIENTS_DIR}/${target}/${target}.pub")"
    RESOLVED_PEER_IP="$(sudo awk -F, -v p="${RESOLVED_PEER_PUB}" '$3==p {print $1; exit}' "${PEER_LIST_FILE}" 2>/dev/null || true)"
    return 0
  fi

  return 1
}

remove_peer_block_from_server_conf() {
  local peer_pub="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  sudo awk -v key="${peer_pub}" '
  function flush_block() {
    if (n == 0) return
    if (!skip) {
      for (i = 1; i <= n; i++) print block[i]
    }
    n = 0
    skip = 0
  }
  {
    if ($0 == "[Peer]") {
      flush_block()
      in_peer = 1
      n = 1
      block[n] = $0
      next
    }

    if (in_peer) {
      n++
      block[n] = $0
      if ($0 ~ /^PublicKey[[:space:]]*=/) {
        line = $0
        sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", line)
        gsub(/[[:space:]]/, "", line)
        if (line == key) skip = 1
      }
      next
    }

    print
  }
  END {
    flush_block()
  }' "${SERVER_WG_CONF_FILE}" >"${tmp_file}"

  sudo install -m 0600 "${tmp_file}" "${SERVER_WG_CONF_FILE}"
  rm -f "${tmp_file}"
}

remove_from_peer_list() {
  local peer_ip="$1"
  local peer_name="$2"
  local peer_pub="$3"
  local tmp_file
  tmp_file="$(mktemp)"
  sudo awk -F, -v ip="${peer_ip}" -v name="${peer_name}" -v pub="${peer_pub}" '
    !($1==ip || $2==name || $3==pub) {print}
  ' "${PEER_LIST_FILE}" >"${tmp_file}"
  sudo install -m 0600 "${tmp_file}" "${PEER_LIST_FILE}"
  rm -f "${tmp_file}"
}

add_to_peer_list() {
  local peer_ip="$1"
  local peer_name="$2"
  local peer_pub="$3"
  remove_from_peer_list "${peer_ip}" "${peer_name}" "${peer_pub}"
  printf "%s,%s,%s\n" "${peer_ip}" "${peer_name}" "${peer_pub}" | sudo tee -a "${PEER_LIST_FILE}" >/dev/null
}

update_hosts_entry() {
  local peer_ip="$1"
  local peer_name="$2"
  local add="${3:-true}"
  local tmp_file
  tmp_file="$(mktemp)"
  sudo awk -v ip="${peer_ip}" -v name="${peer_name}" '
    !($1==ip || $2==name) {print}
  ' /etc/hosts >"${tmp_file}"
  if [[ "${add}" == "true" ]]; then
    printf "%s %s\n" "${peer_ip}" "${peer_name}" >>"${tmp_file}"
  fi
  sudo install -m 0644 "${tmp_file}" /etc/hosts
  rm -f "${tmp_file}"
}

render_client_config() {
  local peer_ip="$1"
  local peer_name="$2"
  local peer_priv_key="$3"
  local server_pub_key="$4"
  local allowed_ips="$5"
  local out_file="${CLIENTS_DIR}/${peer_name}/wg0.conf"
  local tmp_file

  if ! sudo test -f "${CLIENT_TEMPLATE}"; then
    die "Missing client template: ${CLIENT_TEMPLATE}"
  fi

  tmp_file="$(mktemp)"
  sudo sed \
    -e "s|:CLIENT_IP:|${peer_ip}|g" \
    -e "s|:CLIENT_KEY:|${peer_priv_key}|g" \
    -e "s|:SERVER_PUB_KEY:|${server_pub_key}|g" \
    -e "s|:SERVER_ADDRESS:|${SERVER_IP}|g" \
    -e "s|:SERVER_PORT:|${SERVER_PORT}|g" \
    -e "s|:ALLOWED_IPS:/24|${allowed_ips}|g" \
    -e "s|:ALLOWED_IPS:|${allowed_ips}|g" \
    "${CLIENT_TEMPLATE}" >"${tmp_file}"
  sudo install -m 0600 "${tmp_file}" "${out_file}"
  rm -f "${tmp_file}"
}

package_client_files() {
  require_cmd qrencode zip tar
  local peer_name="$1"
  local client_dir="${CLIENTS_DIR}/${peer_name}"
  local tmp_conf tmp_png
  tmp_conf="$(mktemp)"
  tmp_png="$(mktemp)"
  sudo cat "${client_dir}/wg0.conf" >"${tmp_conf}"
  qrencode -o "${tmp_png}" <"${tmp_conf}"
  sudo install -m 0600 "${tmp_png}" "${client_dir}/${peer_name}.png"
  sudo install -m 0755 "${INSTALL_CLIENT_SCRIPT}" "${client_dir}/install-client.sh"
  sudo rm -f "${CLIENTS_DIR}/${peer_name}.zip" "${CLIENTS_DIR}/${peer_name}.tar.gz"
  sudo zip -rq "${CLIENTS_DIR}/${peer_name}.zip" "${client_dir}"
  sudo tar -czf "${CLIENTS_DIR}/${peer_name}.tar.gz" -C "${CLIENTS_DIR}" "${peer_name}"
  rm -f "${tmp_conf}" "${tmp_png}"
}

ensure_server_peer_block() {
  local peer_ip="$1"
  local peer_pub="$2"
  if ! sudo grep -q "PublicKey = ${peer_pub}" "${SERVER_WG_CONF_FILE}"; then
    {
      printf "\n[Peer]\n"
      printf "PublicKey = %s\n" "${peer_pub}"
      printf "AllowedIPs = %s/32\n" "${peer_ip}"
    } | sudo tee -a "${SERVER_WG_CONF_FILE}" >/dev/null
  fi
}

remove_peer_everywhere() {
  local peer_ip="$1"
  local peer_name="$2"
  local peer_pub="$3"

  if [[ -n "${peer_pub}" ]]; then
    sudo wg set wg0 peer "${peer_pub}" remove >/dev/null 2>&1 || true
    if sudo test -f "${SERVER_WG_CONF_FILE}"; then
      remove_peer_block_from_server_conf "${peer_pub}"
    fi
  fi

  if [[ -f "${PEER_LIST_FILE}" ]]; then
    remove_from_peer_list "${peer_ip}" "${peer_name}" "${peer_pub}"
  fi

  if [[ -n "${peer_ip}" || -n "${peer_name}" ]]; then
    update_hosts_entry "${peer_ip}" "${peer_name}" "false"
  fi
}

cmd_add() {
  local peer_name="$1"
  local peer_ip="${PEER_IP}"
  local peer_dir peer_priv_file peer_pub_file peer_priv_key peer_pub_key server_pub_key allowed_ips

  check_string "${peer_name}" "PEER_NAME"
  ensure_layout

  if resolve_peer "${peer_name}"; then
    if [[ "${OVERWRITE}" != "true" ]]; then
      log_warn "Client '${peer_name}' already exists. Use -o to overwrite."
      if sudo test -f "${CLIENTS_DIR}/${peer_name}/wg0.conf"; then
        sudo cat "${CLIENTS_DIR}/${peer_name}/wg0.conf"
      fi
      if [[ "${DISPLAY_QR}" == "true" ]] && sudo test -f "${CLIENTS_DIR}/${peer_name}/wg0.conf"; then
        sudo cat "${CLIENTS_DIR}/${peer_name}/wg0.conf" | qrencode -t ansiutf8
      fi
      return 0
    fi
    if [[ -z "${peer_ip}" ]]; then
      peer_ip="${RESOLVED_PEER_IP}"
    fi
    remove_peer_everywhere "${RESOLVED_PEER_IP}" "${RESOLVED_PEER_NAME}" "${RESOLVED_PEER_PUB}"
  fi

  if [[ -z "${peer_ip}" ]]; then
    peer_ip="$(next_peer_ip)"
  else
    peer_ip="$(check_ip "${peer_ip}")"
  fi

  if [[ -z "${SERVER_IP}" ]]; then
    die "Server IP could not be resolved. Use -s to set one."
  fi
  if ! sudo test -f "${SERVER_PUB_FILE}"; then
    die "Missing server public key file: ${SERVER_PUB_FILE}"
  fi
  if ! sudo test -f "${INSTALL_CLIENT_SCRIPT}"; then
    die "Missing install-client script in tool directory: ${INSTALL_CLIENT_SCRIPT}"
  fi

  peer_dir="${CLIENTS_DIR}/${peer_name}"
  peer_priv_file="${peer_dir}/${peer_name}.pri"
  peer_pub_file="${peer_dir}/${peer_name}.pub"
  sudo mkdir -p "${peer_dir}"
  sudo sh -c "umask 077 && wg genkey | tee '${peer_priv_file}' | wg pubkey >'${peer_pub_file}'"
  peer_priv_key="$(sudo cat "${peer_priv_file}")"
  peer_pub_key="$(sudo cat "${peer_pub_file}")"
  server_pub_key="$(sudo cat "${SERVER_PUB_FILE}")"
  allowed_ips="$(allowed_ips_for_peer "${peer_ip}")"

  render_client_config "${peer_ip}" "${peer_name}" "${peer_priv_key}" "${server_pub_key}" "${allowed_ips}"
  package_client_files "${peer_name}"

  add_to_peer_list "${peer_ip}" "${peer_name}" "${peer_pub_key}"
  set_last_ip "${peer_ip}"

  ensure_server_peer_block "${peer_ip}" "${peer_pub_key}"
  sudo wg set wg0 peer "${peer_pub_key}" allowed-ips "${peer_ip}/32"
  update_hosts_entry "${peer_ip}" "${peer_name}" "true"

  log_success "Client '${peer_name}' created/updated."
  printf "Client config: %s\n" "${peer_dir}/wg0.conf"
  printf "Client packages: %s.zip, %s.tar.gz\n" "${CLIENTS_DIR}/${peer_name}" "${CLIENTS_DIR}/${peer_name}"

  if [[ "${DISPLAY_QR}" == "true" ]]; then
    sudo cat "${peer_dir}/wg0.conf" | qrencode -t ansiutf8
  fi
}

cmd_list() {
  ensure_layout
  printf "\nCurrent Clients:\n"
  local count=1
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    printf "\t%s: %s\n" "${count}" "${line//,/$'\t'}"
    count=$((count + 1))
  done < <(sudo cat "${PEER_LIST_FILE}" 2>/dev/null || true)
  echo
}

cmd_remove() {
  local target="$1"
  if ! resolve_peer "${target}"; then
    die "Could not resolve peer '${target}' by name or public key."
  fi

  remove_peer_everywhere "${RESOLVED_PEER_IP}" "${RESOLVED_PEER_NAME}" "${RESOLVED_PEER_PUB}"
  if [[ "${DELETE_FILES}" == "true" && -n "${RESOLVED_PEER_NAME}" ]]; then
    sudo rm -rf "${CLIENTS_DIR:?}/${RESOLVED_PEER_NAME}"
    sudo rm -f "${CLIENTS_DIR}/${RESOLVED_PEER_NAME}.zip" "${CLIENTS_DIR}/${RESOLVED_PEER_NAME}.tar.gz"
  fi

  log_success "Removed peer '${RESOLVED_PEER_NAME:-${target}}'."
}

cmd_show() {
  local peer_name="${1:-}"
  if [[ -z "${peer_name}" ]]; then
    sudo wg show
    return 0
  fi

  local conf="${CLIENTS_DIR}/${peer_name}/wg0.conf"
  if ! sudo test -f "${conf}"; then
    die "Client config not found: ${conf}"
  fi
  sudo cat "${conf}"
  if [[ "${DISPLAY_QR}" == "true" ]]; then
    sudo cat "${conf}" | qrencode -t ansiutf8
  fi
}

cmd_update() {
  local peer_name="$1"
  if ! resolve_peer "${peer_name}"; then
    die "Peer '${peer_name}' not found."
  fi
  OVERWRITE="true"
  if [[ -z "${PEER_IP}" ]]; then
    PEER_IP="${RESOLVED_PEER_IP}"
  fi
  cmd_add "${peer_name}"
}

cmd_status() {
  sudo wg show
}

while getopts "fhi:op:qs:vD" OPTION; do
  case "${OPTION}" in
    f) FORCE="true" ;;
    h)
      usage
      exit 0
      ;;
    i) PEER_IP="$(check_ip "${OPTARG}")" ;;
    o) OVERWRITE="true" ;;
    p) CLI_SERVER_PORT="${OPTARG}" ;;
    q) DISPLAY_QR="true" ;;
    s) CLI_SERVER_IP="$(check_ip "${OPTARG}")" ;;
    v) VERBOSE="true" ;;
    D) DELETE_FILES="true" ;;
    ?)
      usage
      exit 1
      ;;
  esac
done
shift "$((OPTIND - 1))"

command="${1:-}"
if [[ -z "${command}" ]]; then
  usage
  exit 1
fi
if [[ "${command}" == "help" ]]; then
  usage
  exit 0
fi
shift || true

if [[ "${FORCE}" != "true" ]]; then
  check_root usage
fi

require_cmd awk sed wg
load_server_conf
ensure_layout

case "${command}" in
  add)
    [[ $# -ge 1 ]] || die "add requires a peer name"
    PEER_NAME="$1"
    cmd_add "${PEER_NAME}"
    ;;
  list)
    cmd_list
    ;;
  remove)
    [[ $# -ge 1 ]] || die "remove requires peer name or public key"
    cmd_remove "$1"
    ;;
  show)
    cmd_show "${1:-}"
    ;;
  update)
    [[ $# -ge 1 ]] || die "update requires a peer name"
    cmd_update "$1"
    ;;
  status)
    cmd_status
    ;;
  help)
    usage
    ;;
  *)
    die "Unknown command '${command}'. Use 'help' to list commands."
    ;;
esac
