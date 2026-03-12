#!/bin/bash
# Install instructions for client bundles created by wg-client
# (C) 2021-2026 Richard Dawson

set -euo pipefail

RUN_UPDATES="false"
FORCE="false"
CONF_SOURCE="./wg0.conf"
VERBOSE="false"

usage() {
  cat <<EOF >&2
Usage: ${0} [-fhuv] [-c CONF_FILE]
Install/refresh WireGuard client config on this host.

Options:
  -c CONF_FILE  Path to client config file (default: ./wg0.conf)
  -f            Force run as root.
  -h            Show help.
  -u            Run apt update before package install.
  -v            Verbose output.
EOF
}

log() {
  if [[ "${VERBOSE}" == "true" ]]; then
    printf "%s\n" "$*"
  fi
}

is_pkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"
}

install_package() {
  local pkg="$1"
  if is_pkg_installed "${pkg}"; then
    log "Package '${pkg}' already installed."
  else
    log "Installing '${pkg}'..."
    sudo apt-get -y install "${pkg}"
  fi
}

check_root() {
  if [[ "${UID}" -eq 0 ]]; then
    printf "This script should not be run as root (unless -f is used).\n" >&2
    exit 1
  fi
}

while getopts "c:fhuv" OPTION; do
  case "${OPTION}" in
    c) CONF_SOURCE="${OPTARG}" ;;
    f) FORCE="true" ;;
    h)
      usage
      exit 0
      ;;
    u) RUN_UPDATES="true" ;;
    v) VERBOSE="true" ;;
    ?)
      usage
      exit 1
      ;;
  esac
done
shift "$((OPTIND - 1))"

if [[ "${FORCE}" != "true" ]]; then
  check_root
fi

[[ -f "${CONF_SOURCE}" ]] || {
  printf "Configuration file not found: %s\n" "${CONF_SOURCE}" >&2
  exit 1
}

if [[ "${RUN_UPDATES}" == "true" ]]; then
  sudo apt-get update
fi

install_package "wireguard"
install_package "wireguard-tools"

sudo mkdir -p /etc/wireguard
if ! sudo test -f /etc/wireguard/wg0.conf || ! sudo cmp -s "${CONF_SOURCE}" /etc/wireguard/wg0.conf; then
  sudo install -m 0600 "${CONF_SOURCE}" /etc/wireguard/wg0.conf
  log "Installed new /etc/wireguard/wg0.conf"
else
  log "Existing /etc/wireguard/wg0.conf is already up-to-date."
fi

if ! sudo wg show wg0 >/dev/null 2>&1; then
  sudo wg-quick up wg0
  log "Started wg0 interface."
else
  log "wg0 is already up."
fi

sudo systemctl enable wg-quick@wg0.service >/dev/null
printf "WireGuard client installation complete.\n"

