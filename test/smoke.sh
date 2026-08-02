#!/bin/bash
#
# Runtime smoke gate for the Meilisearch Cloudron package. No box required: it runs the image the
# way Cloudron does (root entrypoint -> start.sh -> tini -> gosu cloudron) and asserts the package
# contract that a build-time check cannot reach.
#
# The contract this defends, in order of what would hurt most if it broke:
#
#   * THE MASTER KEY IS NEVER REGENERATED over an existing store. Every API key Meilisearch issues
#     is derived from the master key, so generating a new one against an existing store silently
#     invalidates every key every client holds. start.sh refuses to boot in that situation rather
#     than "helpfully" making a new one; this asserts both halves — a key on first run, and a
#     hard refusal when the store exists and the key file has gone.
#   * production mode, so every route except GET /health demands a key. Meilisearch's development
#     mode serves an open API, which on a public Cloudron domain is a data breach, not a warning.
#   * the store lives under /app/db, which is a persistentDirs entry SEPARATE from /app/data.
#     Two mounts, not one: /app/data holds the master key, snapshots and dumps; /app/db holds
#     data.ms itself. A smoke test that mounts only /app/data does not fail cleanly -- the boot
#     dies on a read-only rootfs with "cannot create directory /app/db", which looks like a
#     packaging bug and is really a harness bug. Model the platform, or the test lies.
#
# Usage:  test/smoke.sh [image]     (default: ghcr.io/orcvole/meilisearch-cloudron:dev)
#         ENGINE=docker test/smoke.sh   to use docker instead of podman
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

IMAGE="${1:-ghcr.io/orcvole/meilisearch-cloudron:dev}"
ENGINE="${ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
NAME="meili-smoke-$$"
VOL="meili-smoke-vol-$$"
DBVOL="meili-smoke-db-$$"
PORT="${PORT:-17700}"
B="http://127.0.0.1:${PORT}"

fails=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails+1)); }

cleanup() {
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1
  "$ENGINE" volume rm "$VOL" "$DBVOL" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

start_app() {  # start_app <container-name>
  "$ENGINE" run -d --name "$1" \
    --read-only --tmpfs /run --tmpfs /tmp \
    -v "$VOL":/app/data \
    -v "$DBVOL":/app/db \
    -p 127.0.0.1:${PORT}:7700 \
    -e CLOUDRON=1 \
    -e CLOUDRON_APP_ORIGIN="$B" \
    "$IMAGE" >/dev/null 2>&1
}

wait_health() {  # wait_health <seconds>
  local n="$1" code
  for i in $(seq 1 "$n"); do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/health" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  return 1
}

echo "=== smoke: image=${IMAGE} engine=${ENGINE} ==="
"$ENGINE" volume create "$VOL" >/dev/null
"$ENGINE" volume create "$DBVOL" >/dev/null
start_app "$NAME" || { echo "could not start container"; exit 1; }

# 1. Health. GET /health is the one route Meilisearch leaves open, and it is healthCheckPath.
wait_health 60 && ok "GET /health returns 200 without a key" || {
  bad "never became healthy"; "$ENGINE" logs "$NAME" 2>&1 | tail -30; exit 1; }

# 2. The master key exists, is well-formed, and is 0600. Meilisearch accepts any string, so length
#    is our own guarantee of entropy rather than upstream's.
KEY=$("$ENGINE" exec "$NAME" cat /app/data/master-key 2>/dev/null | tr -d '\r\n')
[ "${#KEY}" -ge 32 ] && ok "master key present (${#KEY} chars)" || bad "master key length=${#KEY} (want >= 32)"
perms=$("$ENGINE" exec "$NAME" stat -c '%a %U:%G' /app/data/master-key 2>/dev/null)
[ "$perms" = "600 cloudron:cloudron" ] && ok "master key file is 600 cloudron:cloudron" \
  || bad "master key perms='$perms' (want 600 cloudron:cloudron)"
"$ENGINE" logs "$NAME" 2>&1 | grep -aqF "$KEY" && bad "master key leaked into the logs" || ok "no master key in the logs"

# 3. THE SECURITY CONTRACT: production mode. Every route but /health must demand a key. A 200 on
#    /indexes without a key means the API is open to anyone who can reach the domain.
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/indexes" 2>/dev/null || echo 000)
[ "$code" = "401" ] || [ "$code" = "403" ] && ok "/indexes rejects an unkeyed request (HTTP $code)" \
  || bad "/indexes returned HTTP $code without a key (expected 401/403 — is MEILI_ENV=production?)"

# 4. The key actually works, so 3 is not merely "everything is broken".
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "$B/indexes" 2>/dev/null || echo 000)
[ "$code" = "200" ] && ok "/indexes accepts the master key" || bad "/indexes rejected the master key (HTTP $code)"

# 5. A real document round-trip: index, wait for the async task, then search. This is the only
#    assertion that proves the store is writable and the engine actually works, rather than that
#    it merely answered a health probe.
curl -s -m 10 -X POST "$B/indexes/smoke/documents" \
  -H "Authorization: Bearer ${KEY}" -H 'content-type: application/json' \
  -d '[{"id":1,"title":"smoke test document"}]' >/dev/null 2>&1
hit=0
for i in $(seq 1 20); do
  r=$(curl -s -m 5 -X POST "$B/indexes/smoke/search" -H "Authorization: Bearer ${KEY}" \
        -H 'content-type: application/json' -d '{"q":"smoke"}' 2>/dev/null)
  echo "$r" | grep -q '"id":1' && { hit=1; break; }
  sleep 2
done
[ "$hit" = 1 ] && ok "document indexed and returned by search" || bad "search never returned the indexed document"

# 6. The store is at /app/db/data.ms, a persistentDirs path, NOT under /app/data. Cloudron backs
#    up both, but they are different mounts and the split is deliberate (the store is excluded
#    from the file backup in favour of snapshots). A store written to the wrong one survives no
#    restore.
"$ENGINE" exec "$NAME" sh -c 'test -d /app/db/data.ms' 2>/dev/null \
  && ok "store is at /app/db/data.ms (the persistentDirs path)" \
  || bad "no store at /app/db/data.ms"

# 7. Dropped privileges, and tini is PID 1. Meilisearch installs no SIGTERM handler of its own, so
#    without an init that forwards signals a stop waits out the full grace period and is then
#    SIGKILLed mid-write (field guide #89).
u=$("$ENGINE" exec "$NAME" sh -c 'ps -o user= -C meilisearch 2>/dev/null | head -1' 2>/dev/null | tr -d ' ')
[ "$u" = "cloudron" ] && ok "meilisearch runs as cloudron" || bad "meilisearch runs as '${u:-unknown}' (want cloudron)"
p1=$("$ENGINE" exec "$NAME" sh -c 'cat /proc/1/comm 2>/dev/null' 2>/dev/null | tr -d ' \n')
[ "$p1" = "tini" ] && ok "PID 1 is tini (signals are forwarded)" || bad "PID 1 is '${p1:-unknown}' (want tini)"

# 8. THE ONE THAT PROTECTS DATA: restart over the existing store must REUSE the master key, never
#    mint a new one. A regenerated key silently invalidates every API key every client holds.
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
start_app "$NAME" >/dev/null 2>&1
if wait_health 60; then
  KEY2=$("$ENGINE" exec "$NAME" cat /app/data/master-key 2>/dev/null | tr -d '\r\n')
  [ -n "$KEY2" ] && [ "$KEY" = "$KEY2" ] && ok "master key survived a restart unchanged" \
    || bad "master key CHANGED across a restart — every client API key would be invalidated"
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "$B/indexes/smoke" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && ok "indexed data survived the restart" || bad "index missing after restart (HTTP $code)"
else
  bad "did not become healthy after a restart over the existing store"
fi

# 9. And the refusal: with the store present but the key file gone, start.sh must REFUSE to boot
#    rather than generate a fresh key. Booting here is the data-loss path this test exists for.
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1
"$ENGINE" run --rm -v "$VOL":/app/data -v "$DBVOL":/app/db --entrypoint sh "$IMAGE" -c 'rm -f /app/data/master-key' >/dev/null 2>&1
start_app "$NAME" >/dev/null 2>&1
sleep 12
if wait_health 5; then
  bad "booted with the key file missing over an existing store — it minted a new master key"
else
  "$ENGINE" logs "$NAME" 2>&1 | grep -aqiE 'master.key|refus|missing' \
    && ok "refuses to boot when the key file is gone but the store exists" \
    || bad "did not start, but the logs do not explain why (expected an explicit master-key refusal)"
fi

echo
echo "=== smoke result: ${fails} failure(s) ==="
[ "$fails" = 0 ] || "$ENGINE" logs "$NAME" 2>&1 | tail -40
exit $((fails > 0 ? 1 : 0))
