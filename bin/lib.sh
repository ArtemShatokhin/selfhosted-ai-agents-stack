#!/usr/bin/env bash
# Shared helpers for the open-source operator checks. Source it, do not run it.

set -uo pipefail

RED=''; GRN=''; YEL=''; DIM=''; RST=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
fi

FAILED=0
WARNED=0

ok()   { printf '%s ok   %s %s\n' "${GRN}" "${RST}" "$*"; }
warn() { printf '%s warn %s %s\n' "${YEL}" "${RST}" "$*"; WARNED=$((WARNED+1)); }
fail() { printf '%s FAIL %s %s\n' "${RED}" "${RST}" "$*"; FAILED=$((FAILED+1)); }
note() { printf '%s      %s%s\n' "${DIM}" "$*" "${RST}"; }

# Instance directory, exactly where the kortix CLI writes it.
# KORTIX_SELF_HOST_CONFIG_DIR moves the root; --instance picks the stack.
instance_dir() {
  local instance="${1:-default}"
  printf '%s/%s' "${KORTIX_SELF_HOST_CONFIG_DIR:-$HOME/.config/kortix/self-host}" "$instance"
}

# Fingerprint of the key that encrypts every stored secret. Hash only:
# the value never leaves the shell.
api_key_fingerprint() {
  local envfile="$1"
  [ -r "$envfile" ] || return 1
  local val
  val=$(sed -n 's/^API_KEY_SECRET=//p' "$envfile" | head -n1 | tr -d '"'"'"'\r')
  [ -n "$val" ] || return 1
  printf '%s' "$val" | sha256sum | cut -c1-16
}

env_get() {
  local envfile="$1" key="$2"
  sed -n "s/^${key}=//p" "$envfile" 2>/dev/null | head -n1 | tr -d '"'"'"'\r'
}

human_bytes() {
  awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};printf "%.1f%s",b,u[i]}'
}

have() { command -v "$1" >/dev/null 2>&1; }
