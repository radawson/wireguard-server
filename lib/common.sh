#!/bin/bash
# Shared helpers for wireguard-server scripts.
# (C) 2021-2026 Richard Dawson
VERSION="2.13.0"

set -o pipefail


# Defaults
: "${VERBOSE:=false}"


_supports_color() {
  [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]
}

if _supports_color; then
  COLOR_RED="$(tput setaf 1)"
  COLOR_GREEN="$(tput setaf 2)"
  COLOR_YELLOW="$(tput setaf 3)"
  COLOR_BLUE="$(tput setaf 4)"
  COLOR_RESET="$(tput sgr0)"
else
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_RESET=""
fi

log_info() {
  printf "%s[INFO]%s %s\n" "${COLOR_BLUE}" "${COLOR_RESET}" "$*"
}

log_warn() {
  printf "%s[WARN]%s %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$*" >&2
}

log_error() {
  printf "%s[ERROR]%s %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
}

log_success() {
  printf "%s[OK]%s %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

echo_out() {
  if [[ "${VERBOSE}" == "true" ]]; then
    printf "%s\n" "$*"
  fi
}

die() {
  log_error "$*"
  exit 1
}

check_root() {
  local usage_fn="${1:-}"
  if [[ "${UID}" -eq 0 ]]; then
    log_error "This script should not be run as root."
    if [[ -n "${usage_fn}" ]] && declare -F "${usage_fn}" >/dev/null; then
      "${usage_fn}" >&2
    fi
    exit 1
  fi
}

check_ip() {
  local ip="$1"
  if [[ "${ip}" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]]; then
    printf "%s\n" "${ip}"
    return 0
  fi
  die "'${ip}' is not a valid IPv4 address."
}

check_string() {
  local value="${1:-}"
  local label="${2:-value}"
  if [[ "${value}" =~ [[:space:]\'] ]]; then
    log_warn "Spaces or single quotes found for ${label}; this may cause issues."
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done
}

is_pkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"
}

append_line_once() {
  local line="$1"
  local file="$2"
  touch "${file}"
  if ! grep -Fqx "${line}" "${file}"; then
    printf "%s\n" "${line}" >>"${file}"
  fi
}

replace_or_add_setting() {
  local key="$1"
  local value="$2"
  local file="$3"

  touch "${file}"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf "%s=%s\n" "${key}" "${value}" >>"${file}"
  fi
}
