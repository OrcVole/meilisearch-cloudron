#!/bin/bash
# gate2.sh — data-level differential assertions for a Meilisearch version bump.
# Usage: MEILI_MASTER_KEY=... test/gate2.sh <host> before|after [expected_version]
#
# Written for 1.51.0 -> 1.52.0 (2026-08-03); the version-specific assertions are marked and should
# be refreshed from the upstream diff at each bump. Each assertion is a DIFFERENTIAL: the before
# leg on the old version is the fail-observation for the after leg (#183 — an assertion never seen
# failing is a rumour), so run BOTH legs and keep both outputs in the round notes.
set -uo pipefail
H="https://${1:?host required}"; LEG="${2:?before|after}"; WANT="${3:-}"
K="${MEILI_MASTER_KEY:?master key required}"
AU=(-H "Authorization: Bearer ${K}")
fails=0; ok(){ echo "PASS: $*"; }; bad(){ echo "FAIL: $*"; fails=$((fails+1)); }; note(){ echo "  ~ $*"; }
OUT="/tmp/gate2-meili-${LEG}.json"

# A. identity: which engine version is actually serving
V=$(curl -sf "${AU[@]}" "$H/version" | jq -r .pkgVersion)
note "serving pkgVersion=${V}"
if [ -n "$WANT" ]; then [ "$V" = "$WANT" ] && ok "version ${V} = expected ${WANT}" || bad "version ${V} != expected ${WANT}"; fi

# B. [1.52.0-specific] the new experimental flag exists after, and NOT before.
#    Differential proof: the same jq 'has' check flips across the update.
EF=$(curl -sf "${AU[@]}" "$H/experimental-features")
HASTS=$(echo "$EF" | jq 'has("tasksStreamingRoute")')
if [ "$LEG" = after ]; then
  [ "$HASTS" = "true" ] && ok "experimental-features exposes tasksStreamingRoute (1.52 surface live)" \
                        || bad "tasksStreamingRoute missing after update"
  [ "$(echo "$EF" | jq -r .tasksStreamingRoute)" = "false" ] && ok "tasksStreamingRoute defaults OFF" \
                        || bad "tasksStreamingRoute unexpectedly enabled"
else
  [ "$HASTS" = "false" ] && ok "before-leg: tasksStreamingRoute absent on old version (differential armed)" \
                         || bad "before-leg: flag already present — differential is vacuous"
fi

# C. data preservation: per-index document counts, recorded before, compared after.
STATS=$(curl -sf "${AU[@]}" "$H/stats")
echo "$STATS" | jq -S '{indexes: (.indexes | map_values(.numberOfDocuments))}' > "$OUT"
note "index doc counts: $(jq -c .indexes "$OUT")"
if [ "$LEG" = after ]; then
  if [ -f /tmp/gate2-meili-before.json ]; then
    if diff -q /tmp/gate2-meili-before.json "$OUT" >/dev/null; then
      ok "per-index document counts identical across the update"
    else
      bad "document counts CHANGED across the update:"; diff /tmp/gate2-meili-before.json "$OUT" | sed 's/^/    /'
    fi
  else
    bad "no before-leg baseline found — the comparison never ran (do not report this as a pass)"
  fi
fi

# D. [self-datastore migration] the upgradeDatabase task: THE assertion for the supervised
#    upgrade. On the old version the type itself is invalid (400) — that IS the before-leg proof.
TQ=$(curl -s -o /tmp/gate2-meili-task.json -w '%{http_code}' "${AU[@]}" "$H/tasks?types=upgradeDatabase")
if [ "$LEG" = after ]; then
  ST=$(jq -r '.results[0].status // "ABSENT"' /tmp/gate2-meili-task.json)
  [ "$TQ" = 200 ] && [ "$ST" = "succeeded" ] \
    && ok "upgradeDatabase task ran and succeeded (first real exercise of the supervised upgrade)" \
    || bad "upgradeDatabase: http=${TQ} status=${ST} (want 200/succeeded)"
else
  [ "$TQ" = 400 ] && ok "before-leg: old version rejects the task type (400) — differential armed" \
                  || note "before-leg: tasks?types=upgradeDatabase -> ${TQ} (unexpected; record it)"
fi

echo "=== gate2(meili) leg=${LEG} result: ${fails} failure(s) ==="
exit $fails
