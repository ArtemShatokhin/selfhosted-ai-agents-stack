#!/usr/bin/env bash
# restore — put an open-source Kortix backup back, and refuse the restore that silently breaks
# every stored credential.
#
#   sudo ./bin/restore.sh backups/kortix-default-<stamp>.tgz --instance default [--force]
#
# The archive carries .env, and API_KEY_SECRET in it is the key that encrypts
# every stored secret. Restoring an archive into an instance that already has
# a different API_KEY_SECRET leaves the platform serving with unreadable
# credentials (project secrets marked Undecryptable, connector calls returning
# credential_undecryptable, requests answering 409 SECRET_UNDECRYPTABLE), so
# that case stops here and asks for --force.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=bin/lib.sh
. bin/lib.sh

ARCHIVE="${1:-}"
INSTANCE="default"
FORCE=0
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --instance) INSTANCE="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ARCHIVE" ] || { echo "usage: $0 <archive.tgz> [--instance name] [--force]" >&2; exit 2; }
[ -r "$ARCHIVE" ] || { fail "cannot read $ARCHIVE"; exit 2; }

# 1. Integrity, when we shipped a checksum beside the archive.
if [ -r "${ARCHIVE}.sha256" ]; then
  if (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null 2>&1); then
    ok "checksum matches ${ARCHIVE}.sha256"
  else
    fail "checksum does not match — the archive changed or was truncated; refusing"
    exit 1
  fi
else
  warn "no .sha256 beside the archive; verifying structure only"
fi

# 2. Structure.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$ARCHIVE" -C "$tmp" || { fail "cannot extract $ARCHIVE"; exit 1; }
root="$(find "$tmp" -maxdepth 1 -type d ! -path "$tmp" | head -n1)"
[ -n "$root" ] && [ -r "$root/.env" ] || { fail "archive does not contain an instance directory with .env"; exit 1; }

FP=$(api_key_fingerprint "$root/.env") || { fail "no API_KEY_SECRET in the archived .env — credentials would be unreadable"; exit 1; }
ok "archive API_KEY_SECRET fingerprint ${FP}"

# 3. The check that matters.
DIR="$(instance_dir "$INSTANCE")"
if [ -r "$DIR/.env" ]; then
  CUR=$(api_key_fingerprint "$DIR/.env" || true)
  if [ -n "$CUR" ] && [ "$CUR" != "$FP" ]; then
    if [ "$FORCE" -ne 1 ]; then
      fail "API_KEY_SECRET differs: live instance ${CUR}, archive ${FP}"
      note "restoring replaces the key, so every secret, connector credential and token stored now becomes unreadable"
      note "if that is what you want (a rebuild, not a repair), re-run with --force; the current directory is kept as *.pre-restore-*"
      exit 1
    fi
    warn "API_KEY_SECRET differs (${CUR} → ${FP}); continuing because --force was given"
  elif [ -n "$CUR" ]; then
    ok "API_KEY_SECRET matches the live instance — stored credentials stay readable"
  fi
fi

# 4. Swap directories, keeping the old one.
if have kortix; then
  kortix self-host stop --instance "$INSTANCE" >/dev/null 2>&1 || true
fi
if [ -d "$DIR" ]; then
  keep="${DIR}.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$DIR" "$keep" || { fail "cannot move the current instance directory aside"; exit 1; }
  ok "current directory kept at $keep"
fi
mkdir -p "$(dirname "$DIR")"
cp -a "$root" "$DIR" || { fail "copy failed"; exit 1; }
chmod 600 "$DIR/.env" 2>/dev/null || warn "could not set .env to mode 0600"

if have kortix; then
  if kortix self-host start --instance "$INSTANCE" >/dev/null 2>&1; then
    ok "stack started"
  else
    fail "stack did not start — run: kortix self-host logs --instance ${INSTANCE}"
    exit 1
  fi
  ./bin/doctor.sh "$INSTANCE" || warn "doctor reports failures; fix them before handing the instance back"
else
  note "kortix CLI not on PATH: start the stack yourself with kortix self-host start --instance ${INSTANCE}"
fi
