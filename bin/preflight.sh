#!/usr/bin/env bash
# preflight — for a self-hosted install of the open-source Kortix stack.
# Run it on the server BEFORE `kortix self-host init`.
# Checks the things an install cannot fix after the fact: DNS, ports,
# free disk and the tooling the stack expects.
#
#   ./bin/preflight.sh kortix.example.com
#
# Exit 0 when every check passes, 1 when one fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=bin/lib.sh
. bin/lib.sh

DOMAIN="${1:-${KORTIX_DOMAIN:-}}"
PREVIEW_BASE="${2:-p.${DOMAIN}}"
MIN_DISK_MB="${KORTIX_MIN_FREE_DISK_MB:-2048}"

if [ -z "$DOMAIN" ]; then
  echo "usage: $0 <domain> [preview-base-domain]" >&2
  echo "       e.g. $0 kortix.example.com p.kortix.example.com" >&2
  exit 2
fi

echo "preflight for ${DOMAIN} (preview base: ${PREVIEW_BASE})"
echo

# --- tooling -------------------------------------------------------------
if have docker; then
  ok "docker $(docker --version 2>/dev/null | sed 's/^Docker version //;s/,.*//')"
else
  fail "docker not found — the bootstrap installs it, or install Docker Engine first"
fi

if docker compose version >/dev/null 2>&1; then
  ok "docker compose $(docker compose version --short 2>/dev/null)"
else
  fail "the Compose plugin is missing (docker-compose-plugin) — doctor check 'docker-compose' fails without it"
fi

if have tar && have sha256sum; then
  ok "tar + sha256sum present (backup/restore need both)"
else
  fail "tar and sha256sum are required by backup.sh and restore.sh"
fi

# --- disk and memory -----------------------------------------------------
# The published per-service limits are 2048m for kortix-api, 2048m for
# llm-gateway, 512m for the frontend and a fixed 1280m for Postgres, plus
# images, volumes and one previous release kept for rollback.
free_mb=$(df -Pm / | awk 'NR==2{print $4}')
if [ "${free_mb:-0}" -ge "$MIN_DISK_MB" ]; then
  ok "free disk on /: $(human_bytes $((free_mb*1024*1024))) (floor ${MIN_DISK_MB}MB)"
else
  fail "free disk on /: only ${free_mb}MB, below the ${MIN_DISK_MB}MB floor — the updater stops below it"
fi

if [ -r /proc/meminfo ]; then
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  # 2048 + 2048 + 512 + 1280 = 5888MB of container limits, plus the host.
  if [ "${mem_mb:-0}" -ge 7500 ]; then
    ok "memory: ${mem_mb}MB"
  elif [ "${mem_mb:-0}" -ge 6000 ]; then
    warn "memory: ${mem_mb}MB — the container limits alone need ~5.9GB, no headroom for the host"
  else
    fail "memory: ${mem_mb}MB — below the ~5.9GB of container limits; lower KORTIX_API_MEMORY_LIMIT/KORTIX_GATEWAY_MEMORY_LIMIT or resize"
  fi
fi

# --- ports ---------------------------------------------------------------
for port in 80 443; do
  if have ss; then
    if ss -ltn "sport = :${port}" 2>/dev/null | tail -n +2 | grep -q .; then
      fail "port ${port} already bound — Caddy takes 80 and 443 in domain mode"
    else
      ok "port ${port} free"
    fi
  else
    note "ss not available; cannot check port ${port}"
  fi
done

# --- DNS -----------------------------------------------------------------
resolve_all() {
  local name="$1"
  if have dig; then
    dig +short A "$name" 2>/dev/null
    dig +short AAAA "$name" 2>/dev/null
  elif have getent; then
    getent ahosts "$name" 2>/dev/null | awk '{print $1}'
  fi
}

apex=$(resolve_all "$DOMAIN" | grep -v '\.$' | sort -u)
if [ -z "$apex" ]; then
  fail "$DOMAIN does not resolve — point A/AAAA at this server before the first start (Caddy needs it for the certificate)"
else
  ok "$DOMAIN → $(echo "$apex" | tr '\n' ' ')"
fi

api=$(resolve_all "api.$DOMAIN" | grep -v '\.$' | sort -u)
if [ -z "$api" ]; then
  fail "api.$DOMAIN does not resolve — sessions call back to that URL and will not start without it"
elif [ -n "$apex" ] && [ -z "$(comm -12 <(echo "$apex"|sort -u) <(echo "$api"|sort -u))" ]; then
  fail "api.$DOMAIN points somewhere other than $DOMAIN — both records must point at this server"
else
  ok "api.$DOMAIN → $(echo "$api" | tr '\n' ' ')"
fi

# Wildcard: one random label under the preview base should answer like the apex.
probe="preflight-$RANDOM.$PREVIEW_BASE"
wild=$(resolve_all "$probe" | grep -v '\.$' | sort -u)
if [ -z "$wild" ]; then
  fail "*.${PREVIEW_BASE} does not resolve — previews fall back to a path proxy that breaks root-absolute links, and doctor check 'preview-origins' fails"
else
  ok "*.${PREVIEW_BASE} → $(echo "$wild" | tr '\n' ' ')"
  if [ -n "$apex" ] && [ -z "$(comm -12 <(echo "$apex"|sort -u) <(echo "$wild"|sort -u))" ]; then
    warn "*.${PREVIEW_BASE} resolves elsewhere than $DOMAIN — usually a proxy in front; confirm it reaches this server"
  fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "${RED}${FAILED} check(s) failed${RST} — fix them before init. Re-run this script after the fix."
  exit 1
fi
echo "${GRN}preflight passed${RST}${WARNED:+} (${WARNED} warning(s)). Next: kortix self-host init --domain ${DOMAIN}"
exit 0
