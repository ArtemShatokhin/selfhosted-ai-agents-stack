#!/usr/bin/env bash
# backup — consistent, verifiable backup of a self-hosted open-source Kortix instance.
#
#   sudo ./bin/backup.sh [instance] [destination-dir]
#
# A database dump alone is not the backup: API_KEY_SECRET in .env encrypts
# every stored secret, connector credential and token. This script therefore
# archives the whole instance directory and records a fingerprint of that key
# (a hash, never the value) so a restore can refuse a mismatch.
#
# The stack is stopped for the copy, so Postgres files are consistent, and
# started again by an EXIT trap whatever happens in between.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=bin/lib.sh
. bin/lib.sh

INSTANCE="${1:-${KORTIX_INSTANCE:-default}}"
DEST="${2:-$(pwd)/backups}"
DIR="$(instance_dir "$INSTANCE")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${DEST}/kortix-${INSTANCE}-${STAMP}.tgz"

[ -d "$DIR" ] || { fail "instance directory not found: $DIR"; exit 2; }
[ -r "$DIR/.env" ] || { fail "no .env in $DIR — refusing to archive an instance whose key cannot be fingerprinted"; exit 2; }

FP=$(api_key_fingerprint "$DIR/.env") || { fail "API_KEY_SECRET is missing from $DIR/.env — that key is what makes stored secrets readable"; exit 2; }
mkdir -p "$DEST" || { fail "cannot create $DEST"; exit 2; }

STOPPED=0
restart() {
  if [ "$STOPPED" -eq 1 ]; then
    echo "restarting ${INSTANCE}..."
    kortix self-host start --instance "$INSTANCE" >/dev/null 2>&1 || warn "stack did not restart — run: kortix self-host start --instance ${INSTANCE}"
  fi
}
trap restart EXIT

echo "stopping ${INSTANCE} so the database files are consistent"
if kortix self-host stop --instance "$INSTANCE" >/dev/null 2>&1; then
  STOPPED=1
else
  fail "could not stop ${INSTANCE} — nothing archived (an inconsistent Postgres copy is worse than no copy)"
  exit 1
fi

echo "archiving ${DIR}"
if ! tar -czf "$ARCHIVE" -C "$(dirname "$DIR")" "$(basename "$DIR")"; then
  fail "tar failed — archive removed"
  rm -f "$ARCHIVE"
  exit 1
fi

# Verify contents before calling it a backup.
listing=$(tar -tzf "$ARCHIVE" 2>/dev/null)
missing=""
for want in ".env" "volumes/db/data" "volumes/storage"; do
  printf '%s\n' "$listing" | grep -q "/${want}\(/\|$\)" || missing="${missing} ${want}"
done
if [ -n "$missing" ]; then
  fail "archive is missing:${missing} — do not rely on it"
  exit 1
fi

SUM=$(sha256sum "$ARCHIVE" | awk '{print $1}')
SIZE=$(stat -c%s "$ARCHIVE" 2>/dev/null || echo 0)
printf '%s  %s\n' "$SUM" "$(basename "$ARCHIVE")" > "${ARCHIVE}.sha256"

VERSION="unknown"
if have kortix; then
  VERSION=$(kortix self-host version --instance "$INSTANCE" 2>/dev/null | tr '\n' ' ' | cut -c1-120)
fi

cat > "${ARCHIVE}.manifest.json" <<JSON
{
  "instance": "${INSTANCE}",
  "created_utc": "${STAMP}",
  "archive": "$(basename "$ARCHIVE")",
  "bytes": ${SIZE},
  "sha256": "${SUM}",
  "api_key_secret_fingerprint": "${FP}",
  "kortix_version_output": $(printf '%s' "$VERSION" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),
  "restore": "./bin/restore.sh ${ARCHIVE} --instance ${INSTANCE}"
}
JSON

ok "archive $(human_bytes "$SIZE") → ${ARCHIVE}"
ok "sha256 ${SUM:0:16}… written beside it"
ok "API_KEY_SECRET fingerprint ${FP}"
note "copy the archive, its .sha256 and its .manifest.json off this server"
note "a restore onto an instance with a different API_KEY_SECRET is refused unless --force"
