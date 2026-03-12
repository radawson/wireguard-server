#!/bin/bash
# Install WireGuard on Ubuntu/Debian server
# (C) 2021-2026 Richard Dawson
VERSION="2.13.0"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/lib/common.sh"
if [[ ! -f "${LIB_FILE}" ]]; then
  printf "Missing required library: %s\n" "${LIB_FILE}" >&2
  exit 1
fi
source "${LIB_FILE}"

# Defaults
ADAPTER="$(ip route | awk '/^default / {print $5; exit}')"
BRANCH="main"
FORCE="false"
RUN_UPDATES="false"
OVERWRITE="false"
INSTALL_DIRECTORY="/etc/wireguard"
MA_MODE="false"
SERVER_IP="10.100.200.1"
SERVER_PORT="51820"
SERVER_PRIVATE_FILE="server_key.pri"
SERVER_PUBLIC_FILE="server_key.pub"
TOOL_DIR="${HOME}/wireguard"
CONFIG_DIR="${TOOL_DIR}/config"
CONFIG_OVERRIDE="false"
VERBOSE="false"

usage() {
  cat <<EOF >&2
Usage: ${0} [-dfhmouv] [-c CONFIG_DIR] [-i IP_RANGE] [-n KEY_NAME] [-p LISTEN_PORT] [-t TOOL_DIR]
Sets up and starts a WireGuard server.
Version: ${VERSION}

Options:
  -c CONFIG_DIR   Set configuration directory.
  -d              Use 'dev' branch metadata.
  -f              Force run as root.
  -h, --help      Show this help text.
  -i IP_RANGE     Set server WireGuard IP address.
  -m              Route all traffic through WireGuard server.
  -n KEY_NAME     Set server key file name prefix.
  -o              Overwrite existing server keys/config.
  -p LISTEN_PORT  Set server listen port.
  -t TOOL_DIR     Set tool installation directory.
  -u              Run apt update/dist-upgrade.
  -v              Verbose output.
EOF
}

cleanup() {
  :
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

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

while getopts "c:dfhi:mn:op:t:uv" OPTION; do
  case "${OPTION}" in
    c)
      CONFIG_DIR="${OPTARG}"
      CONFIG_OVERRIDE="true"
      ;;
    d)
      BRANCH="dev"
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
      ;;
    n)
      SERVER_PRIVATE_FILE="${OPTARG}.pri"
      SERVER_PUBLIC_FILE="${OPTARG}.pub"
      ;;
    o)
      OVERWRITE="true"
      ;;
    p)
      SERVER_PORT="${OPTARG}"
      ;;
    t)
      TOOL_DIR="${OPTARG}"
      if [[ "${CONFIG_OVERRIDE}" != "true" ]]; then
        CONFIG_DIR="${TOOL_DIR}/config"
      fi
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

require_cmd awk cmp install ip sed wg

if [[ "${RUN_UPDATES}" == "true" ]]; then
  log_info "Running apt update/dist-upgrade..."
  sudo apt-get update
  sudo apt-get -y dist-upgrade
fi

install_package "wireguard"
install_package "wireguard-tools"
install_package "zip"
install_package "qrencode"

mkdir -p "${TOOL_DIR}" "${CONFIG_DIR}" "${TOOL_DIR}/server" "${TOOL_DIR}/clients"
mkdir -p "${TOOL_DIR}/lib"
sudo mkdir -p -m 0700 "${INSTALL_DIRECTORY}"

cat >"${TOOL_DIR}/server.conf" <<EOF
VERSION="${VERSION}"
ADAPTER="${ADAPTER}"
BRANCH="${BRANCH}"
FORCE="${FORCE}"
INSTALL_DIRECTORY="${INSTALL_DIRECTORY}"
MA_MODE="${MA_MODE}"
SERVER_IP="${SERVER_IP}"
SERVER_PORT="${SERVER_PORT}"
SERVER_PRIVATE_FILE="${SERVER_PRIVATE_FILE}"
SERVER_PUBLIC_FILE="${SERVER_PUBLIC_FILE}"
TOOL_DIR="${TOOL_DIR}"
CONFIG_DIR="${CONFIG_DIR}"
EOF

log_info "Installing config templates..."
copy_if_changed "${SCRIPT_DIR}/config/wg0-server.example.conf" "${CONFIG_DIR}/wg0-server.example.conf" 0644
copy_if_changed "${SCRIPT_DIR}/config/wg0-client.example.conf" "${CONFIG_DIR}/wg0-client.example.conf" 0644
copy_if_changed "${SCRIPT_DIR}/lib/common.sh" "${TOOL_DIR}/lib/common.sh" 0644

server_key_pri_path="${TOOL_DIR}/server/${SERVER_PRIVATE_FILE}"
server_key_pub_path="${TOOL_DIR}/server/${SERVER_PUBLIC_FILE}"
server_wg_conf_path="${TOOL_DIR}/server/wg0.conf"
installed_wg_conf_path="${INSTALL_DIRECTORY}/wg0.conf"

if [[ "${OVERWRITE}" == "true" || ! -f "${server_key_pri_path}" || ! -f "${server_key_pub_path}" ]]; then
  log_info "Generating server key pair..."
  umask 077
  wg genkey | tee "${server_key_pri_path}" | wg pubkey >"${server_key_pub_path}"
else
  log_info "Server key pair already exists; keeping existing keys."
fi

if [[ ! -s "${server_key_pri_path}" ]]; then
  die "Server private key is missing or empty: ${server_key_pri_path}"
fi

SERVER_PRI_KEY="$(cat "${server_key_pri_path}")"
tmp_wg_conf="$(mktemp)"
sed \
  -e "s|:SERVER_IP:|${SERVER_IP}|g" \
  -e "s|:SERVER_PORT:|${SERVER_PORT}|g" \
  -e "s|:SERVER_KEY:|${SERVER_PRI_KEY}|g" \
  -e "s|:ADAPTER:|${ADAPTER}|g" \
  "${CONFIG_DIR}/wg0-server.example.conf" >"${tmp_wg_conf}"

if [[ "${OVERWRITE}" == "true" || ! -f "${server_wg_conf_path}" || ! -s "${server_wg_conf_path}" ]]; then
  install -m 0600 "${tmp_wg_conf}" "${server_wg_conf_path}"
  log_info "Generated ${server_wg_conf_path}"
elif ! cmp -s "${tmp_wg_conf}" "${server_wg_conf_path}"; then
  log_warn "Existing ${server_wg_conf_path} differs from template; preserving existing file (use -o to overwrite)."
else
  echo_out "Server config is already up-to-date."
fi
rm -f "${tmp_wg_conf}"

sudo install -m 0600 "${server_wg_conf_path}" "${installed_wg_conf_path}"

SERVER_PUB_KEY="$(cat "${server_key_pub_path}")"
peer_list_file="${TOOL_DIR}/peer_list.txt"
last_ip_file="${TOOL_DIR}/last_ip.txt"
touch "${peer_list_file}"

if grep -qE "^${SERVER_IP},server," "${peer_list_file}"; then
  sed -i "s|^${SERVER_IP},server,.*|${SERVER_IP},server,${SERVER_PUB_KEY}|" "${peer_list_file}"
else
  printf "%s\n" "${SERVER_IP},server,${SERVER_PUB_KEY}" >>"${peer_list_file}"
fi
printf "%s\n" "${SERVER_IP}" >"${last_ip_file}"

log_info "Installing tool scripts..."
copy_if_changed "${SCRIPT_DIR}/tools/add-client.sh" "${TOOL_DIR}/add-client.sh" 0755
copy_if_changed "${SCRIPT_DIR}/tools/install-client.sh" "${TOOL_DIR}/install-client.sh" 0755
copy_if_changed "${SCRIPT_DIR}/tools/remove-client.sh" "${TOOL_DIR}/remove-client.sh" 0755
copy_if_changed "${SCRIPT_DIR}/tools/wg-client.sh" "${TOOL_DIR}/wg-client.sh" 0755
if ! sudo test -f "/usr/local/bin/wg-client" || ! sudo cmp -s "${SCRIPT_DIR}/tools/wg-client.sh" "/usr/local/bin/wg-client"; then
  sudo install -m 0755 "${SCRIPT_DIR}/tools/wg-client.sh" "/usr/local/bin/wg-client"
fi

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
  if ! sudo ufw status | grep -q "ALLOW IN.*wg0"; then
    sudo ufw route allow in on wg0 out on "${ADAPTER}"
  fi
fi

sudo systemctl enable wg-quick@wg0.service >/dev/null

log_success "WireGuard server setup complete."
printf "\nServer details:\n"
printf "  Tool directory: %s\n" "${TOOL_DIR}"
printf "  Server IP:      %s\n" "${SERVER_IP}"
printf "  Listen port:    %s\n" "${SERVER_PORT}"
printf "  Public key:     %s\n\n" "${SERVER_PUB_KEY}"
