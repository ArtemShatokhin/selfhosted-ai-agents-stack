#!/usr/bin/env bash
# check-signup — for a reachable self-hosted open-source instance, answer the
# one question that decides whether it is safe: can a stranger create an account?
#
#   ./bin/check-signup.sh https://kortix.example.com     # probe a live instance
#   ./bin/check-signup.sh --instance default             # read the local .env
#
# 0 = closed or email-verified, 1 = open, 2 = could not determine.
#
# The public auth settings endpoint is /auth/v1/settings (GoTrue behind Kong).
# It reports disable_signup and mailer_autoconfirm without credentials.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=bin/lib.sh
. bin/lib.sh

target="${1:-}"
if [ -z "$target" ]; then
  echo "usage: $0 <https://domain> | --instance <name>" >&2
  exit 2
fi

verdict_from_json() {
  python3 - "$1" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception:
    print("could not parse the settings response"); sys.exit(2)
signup_off = bool(d.get("disable_signup", False))
autoconfirm = bool(d.get("mailer_autoconfirm", False))
providers = [k for k, v in (d.get("external") or {}).items() if v]
print(f"disable_signup={signup_off} mailer_autoconfirm={autoconfirm} external={','.join(providers) or 'none'}")
if signup_off:
    print("CLOSED — only an existing user or a platform admin can create an account"); sys.exit(0)
if autoconfirm:
    print("OPEN — sign-up accepts any address and confirms it without an email.")
    print("      Whoever signs up first with an admin-listed address becomes platform admin.")
    print("      fix: kortix self-host env set DISABLE_SIGNUP=true   (or set EMAIL_URL), then kortix self-host start")
    sys.exit(1)
print("OPEN, email-verified — sign-up works but each address must prove itself over email")
sys.exit(0)
PY
}

if [ "$target" = "--instance" ]; then
  INSTANCE="${2:-${KORTIX_INSTANCE:-default}}"
  envfile="$(instance_dir "$INSTANCE")/.env"
  if [ ! -r "$envfile" ]; then
    fail "no readable .env at $envfile — wrong instance name, or the stack was never initialised"
    exit 2
  fi
  disable=$(env_get "$envfile" DISABLE_SIGNUP)
  email_url=$(env_get "$envfile" EMAIL_URL)
  echo "instance: $INSTANCE ($envfile)"
  if [ "$disable" = "true" ]; then
    ok "DISABLE_SIGNUP=true — sign-up closed"
    exit 0
  fi
  if [ -n "$email_url" ]; then
    ok "EMAIL_URL is set — sign-up requires a confirmed email address"
    exit 0
  fi
  fail "sign-up open and email confirmation off (no DISABLE_SIGNUP, no EMAIL_URL)"
  note "until this is fixed, anyone who reaches the instance can create a confirmed account for any address, the admin address included"
  exit 1
fi

base="${target%/}"
echo "probing ${base}/auth/v1/settings"
body=$(curl -fsS --max-time 15 "${base}/auth/v1/settings" 2>/dev/null)
if [ -z "$body" ]; then
  fail "no answer from ${base}/auth/v1/settings — is the stack up and Caddy routing /auth/v1?"
  note "read the value locally instead: $0 --instance <name>"
  exit 2
fi
verdict_from_json "$body"
