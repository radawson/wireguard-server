#!/bin/bash
# Install WireGuard on Ubuntu/Debian server
# (C) 2021-2026 Richard Dawson
VERSION="2.13.1"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE_LOCAL="${SCRIPT_DIR}/lib/common.sh"
LIB_FILE_INSTALLED="/usr/local/share/wireguard/lib/common.sh"
RAW_REPO_BASE="${WG_REPO_RAW_BASE:-https://raw.githubusercontent.com/radawson/wireguard-server}"
RAW_BRANCH="${WG_REPO_BRANCH:-main}"
for arg in "$@"; do
  if [[ "${arg}" == "-d" ]]; then
    RAW_BRANCH="dev"
    break
  fi
done

DOWNLOAD_TMP_DIR="$(mktemp -d)"
download_raw_file() {
  local rel_path="$1"
  local out_path="$2"
  local raw_url="${RAW_REPO_BASE}/${RAW_BRANCH}/${rel_path}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${raw_url}" -o "${out_path}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${out_path}" "${raw_url}"
  else
    printf "Missing downloader: install curl or wget.\n" >&2
    exit 1
  fi
}

COMMON_SOURCE_FILE=""
if [[ -f "${LIB_FILE_LOCAL}" ]]; then
  LIB_FILE="${LIB_FILE_LOCAL}"
  COMMON_SOURCE_FILE="${LIB_FILE_LOCAL}"
elif [[ -f "${LIB_FILE_INSTALLED}" ]]; then
  LIB_FILE="${LIB_FILE_INSTALLED}"
  COMMON_SOURCE_FILE="${LIB_FILE_INSTALLED}"
else
  LIB_FILE="${DOWNLOAD_TMP_DIR}/common.sh"
  if ! download_raw_file "lib/common.sh" "${LIB_FILE}"; then
    printf "Failed to download lib/common.sh from %s/%s\n" "${RAW_REPO_BASE}" "${RAW_BRANCH}" >&2
    exit 1
  fi
  COMMON_SOURCE_FILE="${LIB_FILE}"
fi
source "${LIB_FILE}"

# Defaults
ADAPTER="${ADAPTER:-$(ip route | awk '/^default / {print $5; exit}')}"
if [[ -z "${ADAPTER}" ]]; then
  die "Could not detect default network adapter. Set ADAPTER env variable or ensure a default route exists."
fi
BRANCH="main"
CLIENT_ALLOWED_IPS="10.100.200.0/24"
FORCE="false"
RUN_UPDATES="false"
OVERWRITE="false"
MA_MODE="false"
SERVER_IP="10.100.200.1"
SERVER_ENDPOINT="$(ip -o route get to 1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)"
SERVER_PORT="51820"
SERVER_PRIVATE_FILE="server_key.pri"
SERVER_PUBLIC_FILE="server_key.pub"
VERBOSE="false"

INSTALL_DIRECTORY="${WG_DIR}"
CONFIG_DIR="${WG_DIR}/config"
SERVER_DIR="${WG_DIR}/server"
CLIENTS_DIR="${WG_DIR}/clients"
PEER_LIST_FILE="${WG_DIR}/peer_list.txt"
LAST_IP_FILE="${WG_DIR}/last_ip.txt"
SERVER_WG_CONF_PATH="${SERVER_DIR}/wg0.conf"
INSTALLED_WG_CONF_PATH="${WG_DIR}/wg0.conf"
WG_CLIENT_BIN="/usr/local/bin/wg-client"
WG_SHARE_LIB="${WG_SHARE}/lib/common.sh"
WG_SHARE_INSTALL_CLIENT="${WG_SHARE}/install-client.sh"

usage() {
  cat <<EOF >&2
Usage: ${0} [-defhmouv] [-i IP_RANGE] [-n KEY_NAME] [-p LISTEN_PORT]
Sets up and starts a WireGuard server.
Version: ${VERSION}

Options:
  -d              Use 'dev' branch metadata.
  -e ENDPOINT_IP  Set server endpoint IP clients should connect to.
  -f              Force run as root.
  -h, --help      Show this help text.
  -i IP_RANGE     Set server WireGuard IP address.
  -m              Route all traffic through WireGuard server.
  -n KEY_NAME     Set server key file name prefix.
  -o              Overwrite existing server keys/config.
  -p LISTEN_PORT  Set server listen port.
  -u              Run apt update/dist-upgrade.
  -v              Verbose output.
EOF
}

cleanup() {
  rm -rf "${DOWNLOAD_TMP_DIR}"
}
trap cleanup EXIT

install_package() {
  local pkg="$1"
  if is_pkg_installed "${pkg}"; then
    echo_out "Package '${pkg}' already installed."
  else
    log_info "Installing package: ${pkg}"
    sudo apt-get -y install "${pkg}"
  fi
}

copy_if_changed() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0644}"

  if [[ ! -f "${src}" ]]; then
    die "Required source file missing: ${src}"
  fi

  if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
    echo_out "No changes for ${dst}"
    return 0
  fi

  install -m "${mode}" "${src}" "${dst}"
}

copy_if_changed_sudo() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0644}"

  if [[ ! -f "${src}" ]]; then
    die "Required source file missing: ${src}"
  fi

  if sudo test -f "${dst}" && sudo cmp -s "${src}" "${dst}"; then
    echo_out "No changes for ${dst}"
    return 0
  fi

  sudo install -m "${mode}" "${src}" "${dst}"
}

resolve_repo_source() {
  local rel_path="$1"
  local local_path="${SCRIPT_DIR}/${rel_path}"
  local out_path="${DOWNLOAD_TMP_DIR}/${rel_path##*/}"
  if [[ -f "${local_path}" ]]; then
    printf "%s\n" "${local_path}"
    return 0
  fi
  log_warn "Missing local file '${local_path}', downloading from ${RAW_REPO_BASE}/${RAW_BRANCH}/${rel_path}"
  download_raw_file "${rel_path}" "${out_path}" || die "Failed downloading '${rel_path}' from GitHub raw."
  printf "%s\n" "${out_path}"
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

while getopts "de:fhi:mn:op:uv" OPTION; do
  case "${OPTION}" in
    d)
      BRANCH="dev"
      ;;
    e)
      SERVER_ENDPOINT="$(check_ip "${OPTARG}")"
      ;;
    f)
      FORCE="true"
      ;;
    h)
      usage
      exit 0
      ;;
    i)
      SERVER_IP="$(check_ip "${OPTARG}")"
      ;;
    m)
      MA_MODE="true"
      CLIENT_ALLOWED_IPS="0.0.0.0/0"
      ;;
    n)
      validate_name "${OPTARG}" "key name"
      SERVER_PRIVATE_FILE="${OPTARG}.pri"
      SERVER_PUBLIC_FILE="${OPTARG}.pub"
      ;;
    o)
      OVERWRITE="true"
      ;;
    p)
      SERVER_PORT="${OPTARG}"
      ;;
    u)
      RUN_UPDATES="true"
      ;;
    v)
      VERBOSE="true"
      ;;
    ?)
      usage
      exit 1
      ;;
  esac
done
shift "$((OPTIND - 1))"

if [[ "${FORCE}" != "true" ]]; then
  check_root usage
fi

require_cmd awk cmp install ip sed

if [[ "${RUN_UPDATES}" == "true" ]]; then
  log_info "Running apt update/dist-upgrade..."
  sudo apt-get update
  sudo apt-get -y dist-upgrade
fi

install_package "wireguard"
install_package "wireguard-tools"
install_package "zip"
install_package "qrencode"

sudo mkdir -p -m 0700 "${INSTALL_DIRECTORY}"
sudo mkdir -p "${CONFIG_DIR}" "${SERVER_DIR}" "${CLIENTS_DIR}" "${WG_SHARE}/lib"

cat <<EOF | sudo_write "${WG_CONF}" 0600
VERSION="${VERSION}"
ADAPTER="${ADAPTER}"
BRANCH="${BRANCH}"
CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS}"
FORCE="${FORCE}"
INSTALL_DIRECTORY="${INSTALL_DIRECTORY}"
MA_MODE="${MA_MODE}"
SERVER_IP="${SERVER_IP}"
SERVER_ENDPOINT="${SERVER_ENDPOINT}"
SERVER_PORT="${SERVER_PORT}"
SERVER_PRIVATE_FILE="${SERVER_PRIVATE_FILE}"
SERVER_PUBLIC_FILE="${SERVER_PUBLIC_FILE}"
CONFIG_DIR="${CONFIG_DIR}"
EOF

log_info "Installing config templates..."
SERVER_TEMPLATE_SOURCE="$(resolve_repo_source "config/wg0-server.example.conf")"
CLIENT_TEMPLATE_SOURCE="$(resolve_repo_source "config/wg0-client.example.conf")"
INSTALL_CLIENT_SOURCE="$(resolve_repo_source "tools/install-client.sh")"
WG_CLIENT_SOURCE="$(resolve_repo_source "tools/wg-client.sh")"
copy_if_changed_sudo "${SERVER_TEMPLATE_SOURCE}" "${CONFIG_DIR}/wg0-server.example.conf" 0644
copy_if_changed_sudo "${CLIENT_TEMPLATE_SOURCE}" "${CONFIG_DIR}/wg0-client.example.conf" 0644
copy_if_changed_sudo "${COMMON_SOURCE_FILE}" "${WG_SHARE_LIB}" 0644
copy_if_changed_sudo "${INSTALL_CLIENT_SOURCE}" "${WG_SHARE_INSTALL_CLIENT}" 0755

server_key_pri_path="${SERVER_DIR}/${SERVER_PRIVATE_FILE}"
server_key_pub_path="${SERVER_DIR}/${SERVER_PUBLIC_FILE}"

if [[ "${OVERWRITE}" == "true" ]] || ! sudo test -f "${server_key_pri_path}" || ! sudo test -f "${server_key_pub_path}"; then
  log_info "Generating server key pair..."
  run_priv bash -c 'umask 077 && wg genkey | tee "$1" | wg pubkey >"$2"' _ "${server_key_pri_path}" "${server_key_pub_path}"
else
  log_info "Server key pair already exists; keeping existing keys."
fi

if ! sudo test -s "${server_key_pri_path}"; then
  die "Server private key is missing or empty: ${server_key_pri_path}"
fi

SERVER_PRI_KEY="$(sudo cat "${server_key_pri_path}")"
tmp_wg_conf="$(mktemp)"
sudo sed \
  -e "s|:SERVER_IP:|${SERVER_IP}|g" \
  -e "s|:SERVER_PORT:|${SERVER_PORT}|g" \
  -e "s|:SERVER_KEY:|${SERVER_PRI_KEY}|g" \
  -e "s|:ADAPTER:|${ADAPTER}|g" \
  "${CONFIG_DIR}/wg0-server.example.conf" >"${tmp_wg_conf}"

if [[ "${OVERWRITE}" == "true" ]] || ! sudo test -f "${SERVER_WG_CONF_PATH}" || ! sudo test -s "${SERVER_WG_CONF_PATH}"; then
  sudo install -m 0600 "${tmp_wg_conf}" "${SERVER_WG_CONF_PATH}"
  log_info "Generated ${SERVER_WG_CONF_PATH}"
elif ! sudo cmp -s "${tmp_wg_conf}" "${SERVER_WG_CONF_PATH}"; then
  log_warn "Existing ${SERVER_WG_CONF_PATH} differs from template; preserving existing file (use -o to overwrite)."
else
  echo_out "Server config is already up-to-date."
fi
rm -f "${tmp_wg_conf}"

sudo install -m 0600 "${SERVER_WG_CONF_PATH}" "${INSTALLED_WG_CONF_PATH}"

SERVER_PUB_KEY="$(sudo cat "${server_key_pub_path}")"
sudo touch "${PEER_LIST_FILE}"

if sudo grep -qE "^${SERVER_IP},server," "${PEER_LIST_FILE}"; then
  sudo sed -i "s|^${SERVER_IP},server,.*|${SERVER_IP},server,${SERVER_PUB_KEY}|" "${PEER_LIST_FILE}"
else
  printf "%s\n" "${SERVER_IP},server,${SERVER_PUB_KEY}" | sudo tee -a "${PEER_LIST_FILE}" >/dev/null
fi
printf "%s\n" "${SERVER_IP}" | sudo tee "${LAST_IP_FILE}" >/dev/null

log_info "Installing tool scripts..."
copy_if_changed_sudo "${WG_CLIENT_SOURCE}" "${WG_CLIENT_BIN}" 0755

log_info "Ensuring IPv4 forwarding is enabled..."
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null
sudo sed -i 's|^#\?net.ipv4.ip_forward=.*|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sudo sysctl -p >/dev/null

if ! sudo wg show wg0 >/dev/null 2>&1; then
  log_info "Starting WireGuard interface wg0..."
  sudo wg-quick up wg0
else
  log_info "WireGuard interface wg0 already active; skipping wg-quick up."
fi

if ! sudo ufw status | grep -q "${SERVER_PORT}/udp"; then
  log_info "Opening firewall port ${SERVER_PORT}/udp"
  sudo ufw allow "${SERVER_PORT}/udp"
else
  echo_out "Firewall rule for ${SERVER_PORT}/udp already exists."
fi

if [[ "${MA_MODE}" == "true" ]]; then
  if ! sudo ufw status | grep -q "in on wg0 out on ${ADAPTER}"; then
    sudo ufw route allow in on wg0 out on "${ADAPTER}"
  fi
fi

sudo systemctl enable wg-quick@wg0.service >/dev/null

log_success "WireGuard server setup complete."
printf "\nServer details:\n"
printf "  Data directory: %s\n" "${WG_DIR}"
printf "  Server IP:      %s\n" "${SERVER_IP}"
printf "  Endpoint IP:    %s\n" "${SERVER_ENDPOINT}"
printf "  Listen port:    %s\n" "${SERVER_PORT}"
printf "  Public key:     %s\n\n" "${SERVER_PUB_KEY}"
printf "Run `wg-client add <name>` to add a client.\n"
