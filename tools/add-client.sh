#!/bin/bash
# Backward-compatible wrapper for wg-client add
# (C) 2021-2026 Richard Dawson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/../lib/common.sh"
if [[ ! -f "${LIB_FILE}" ]]; then
  LIB_FILE="${HOME}/wireguard/lib/common.sh"
fi
if [[ ! -f "${LIB_FILE}" ]]; then
  printf "Missing required library file. Expected ../lib/common.sh or ~/wireguard/lib/common.sh\n" >&2
  exit 1
fi
source "${LIB_FILE}"

WG_CLIENT="${SCRIPT_DIR}/wg-client.sh"
if [[ ! -f "${WG_CLIENT}" ]]; then
  WG_CLIENT="${HOME}/wireguard/wg-client.sh"
fi

usage() {
  cat <<EOF >&2
Usage: ${0} [options] PEER_NAME
Compatibility wrapper for: wg-client add

Options:
  -f              Force run as root.
  -h              Show help.
  -i IP_ADDRESS   Set peer IP.
  -l              List existing clients.
  -o              Overwrite existing client config.
  -p SERVER_PORT  Override server listen port.
  -q              Display QR code.
  -s SERVER_IP    Override server endpoint IP.
  -t TOOL_DIR     Override tool directory.
  -v              Verbose output.
EOF
}

FORWARD_ARGS=()
LIST_ONLY="false"

while getopts "fhi:lop:qs:t:v" OPTION; do
  case "${OPTION}" in
    f|i|o|p|q|s|t|v)
      FORWARD_ARGS+=("-${OPTION}")
      if [[ "${OPTION}" == "i" || "${OPTION}" == "p" || "${OPTION}" == "s" || "${OPTION}" == "t" ]]; then
        FORWARD_ARGS+=("${OPTARG}")
      fi
      ;;
    l) LIST_ONLY="true" ;;
    h)
      usage
      exit 0
      ;;
    ?)
      usage
      exit 1
      ;;
  esac
done
shift "$((OPTIND - 1))"

[[ -f "${WG_CLIENT}" ]] || die "Unable to find wg-client.sh"

if [[ "${LIST_ONLY}" == "true" ]]; then
  exec bash "${WG_CLIENT}" "${FORWARD_ARGS[@]}" list
fi

[[ $# -ge 1 ]] || {
  usage
  exit 1
}

PEER_NAME="$1"
exec bash "${WG_CLIENT}" "${FORWARD_ARGS[@]}" add "${PEER_NAME}"
