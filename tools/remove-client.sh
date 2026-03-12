#!/bin/bash
# Backward-compatible wrapper for wg-client remove
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
Usage: ${0} [options] PEER_NAME_OR_PUBLIC_KEY
Compatibility wrapper for: wg-client remove

Options:
  -d              Delete client files and archives.
  -f              Force run as root.
  -h              Show help.
  -t TOOL_DIR     Override tool directory.
  -v              Verbose output.
EOF
}

FORWARD_ARGS=()
DELETE_FILES="false"

while getopts "dfht:v" OPTION; do
  case "${OPTION}" in
    d) DELETE_FILES="true" ;;
    f|t|v)
      FORWARD_ARGS+=("-${OPTION}")
      if [[ "${OPTION}" == "t" ]]; then
        FORWARD_ARGS+=("${OPTARG}")
      fi
      ;;
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

[[ $# -ge 1 ]] || {
  usage
  exit 1
}

TARGET="$1"
if [[ "${DELETE_FILES}" == "true" ]]; then
  FORWARD_ARGS+=("-D")
fi

exec bash "${WG_CLIENT}" "${FORWARD_ARGS[@]}" remove "${TARGET}"