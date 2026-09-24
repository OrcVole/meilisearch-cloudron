#!/bin/bash
#
# Cloudron backupCommand for Meilisearch.
#
# The platform runs this in a TEMPORARY container immediately before it walks /app/data, and the
# conditions there are not the conditions the app itself runs under:
#
#   * no CLOUDRON_* environment variables, so this script cannot learn the app's own address from
#     its environment; it reads /app/data/.endpoint, which the entrypoint writes on every boot;
#   * stdout and stderr are discarded, so the only durable record of what happened is the status
#     line this script appends to /app/data/.last-backup.log;
#   * the root filesystem is read-only, with /tmp and /run as tmpfs; /app/data and /app/db are
#     mounted, and /app/data is writable;
#   * it is attached to the cloudron network, so the app container is reachable by IP.
#
# It asks the running instance for a snapshot through its own API, because a snapshot is what
# Meilisearch itself considers a consistent, restorable artefact; a raw file copy of a live LMDB
# store is not. The snapshot lands in /app/data/snapshots, inside the tree the platform is about
# to back up, and the boot decision tree in start.sh imports it on a clone or a rollback restore.
#
# It exits 0 in every case, deliberately. A backup command that fails takes the platform's whole
# backup run down with it (read from Cloudron 10.0.4's backuptask.js: fullBackup rethrows the first
# app error from inside its app loop, so every later app, mail and system data go unbacked; field
# guide #312), which is a worse outcome than a backup whose snapshot is one cycle stale.
#
# Since 1.2.0 a failure is no longer silent: it writes /app/data/BACKUP-FAILED.txt, which start.sh
# prints on every boot until a later backup succeeds and removes it (a reviewer's finding, forum post
# 129974). And after the snapshot it also takes a DUMP: a snapshot is the store as this version lays
# it out, while a dump is Meilisearch's version-portable artefact, and the boot tree's
# upgrade-failure fallback reads dumps that, before 1.2.0, nothing ever produced (field guide #313).
# Set MEILISEARCH_BACKUP_DUMP=false in /app/data/env to skip the dump on a store too large to dump
# within the poll budget.

set -uo pipefail

DATA=/app/data
SNAPDIR="${DATA}/snapshots"
ENDPOINT_FILE="${DATA}/.endpoint"
KEYFILE="${DATA}/master-key"
LOGFILE="${DATA}/.last-backup.log"
FAILFILE="${DATA}/BACKUP-FAILED.txt"
DUMPDIR="${DATA}/dumps"
LOG_MAX_LINES=100
POLL_INTERVAL=5
POLL_TIMEOUT=600
RETAIN_SNAPSHOTS="${MEILISEARCH_RETAIN_SNAPSHOTS:-2}"
RETAIN_DUMPS=1

# The operator's override file, read for this one variable only: sourcing the whole file in a
# temporary container would run whatever else it contains in a context it was never written for.
BACKUP_DUMP=true
if [[ -r "${DATA}/env" ]]; then
  v="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?MEILISEARCH_BACKUP_DUMP=["'"'"']\?\([A-Za-z]*\).*/\2/p' "${DATA}/env" 2>/dev/null | tail -n 1)"
  [[ "${v}" == false ]] && BACKUP_DUMP=false
fi

# Append one line to the status log, then trim it. Every step tolerates failure, because a
# read-only or full /app/data must not turn into a non-zero exit.
record() {
  local outcome="$1" detail="$2" line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${outcome} ${detail}"
  echo "${line}" >> "${LOGFILE}" 2>/dev/null || return 0
  local count
  count="$(wc -l < "${LOGFILE}" 2>/dev/null || echo 0)"
  if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > LOG_MAX_LINES )); then
    tail -n "${LOG_MAX_LINES}" "${LOGFILE}" > "${LOGFILE}.trim" 2>/dev/null \
      && mv "${LOGFILE}.trim" "${LOGFILE}" 2>/dev/null || true
  fi
  return 0
}

# A failure the operator can see: the file stays until a later backup fully succeeds, and start.sh
# prints it on every boot.
fail_visibly() {
  record failed "$1"
  printf '%s backup failed: %s\nThe backup completed without a fresh search snapshot; a restore of it\nreturns the previous snapshot. Details: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${LOGFILE}" > "${FAILFILE}" 2>/dev/null || true
  exit 0
}

# Poll one Meilisearch task to a final state within the budget. Echoes the final status.
poll_task() {
  local uid="$1" deadline status=unknown
  deadline=$(( $(date +%s) + POLL_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    status="$(curl -fsS -m 15 -H "Authorization: Bearer ${KEY}" "${ENDPOINT}/tasks/${uid}" 2>/dev/null \
      | jq -r '.status // "unreachable"' 2>/dev/null || echo unreachable)"
    case "${status}" in succeeded|failed|canceled) break ;; *) sleep "${POLL_INTERVAL}" ;; esac
  done
  echo "${status}"
}

# Nothing below this point may exit non-zero. Every failure path calls record and exits 0.

if [[ ! -r "${ENDPOINT_FILE}" ]]; then
  fail_visibly "no endpoint file at ${ENDPOINT_FILE}; the app has not booted since install"
fi
ENDPOINT="$(tr -d '[:space:]' < "${ENDPOINT_FILE}" 2>/dev/null || true)"
if [[ -z "${ENDPOINT}" ]]; then
  fail_visibly "endpoint file is empty"
fi

if [[ ! -r "${KEYFILE}" ]]; then
  fail_visibly "cannot read the master key at ${KEYFILE}"
fi
KEY="$(tr -d '[:space:]' < "${KEYFILE}" 2>/dev/null || true)"
if [[ -z "${KEY}" ]]; then
  fail_visibly "master key file is empty"
fi

# Is the instance actually up? A dead app must cost one connection timeout, not ten minutes.
if ! curl -fsS -m 15 -o /dev/null "${ENDPOINT}/health" 2>/dev/null; then
  fail_visibly "no healthy response from ${ENDPOINT}/health; app stopped or unreachable"
fi

RESPONSE="$(curl -fsS -m 60 -X POST "${ENDPOINT}/snapshots" \
  -H "Authorization: Bearer ${KEY}" 2>/dev/null || true)"
TASK_UID="$(printf '%s' "${RESPONSE}" | jq -r '.taskUid // empty' 2>/dev/null || true)"
if [[ -z "${TASK_UID}" ]]; then
  fail_visibly "POST ${ENDPOINT}/snapshots did not return a task uid"
fi

STATUS="$(poll_task "${TASK_UID}")"

if [[ "${STATUS}" != succeeded ]]; then
  fail_visibly "snapshot task ${TASK_UID} ended as ${STATUS} (timeout ${POLL_TIMEOUT}s)"
fi

# Prune to the newest few snapshots before the platform walks the tree, so the backup carries one
# usable artefact rather than every snapshot ever taken. Best effort, like everything else here.
if [[ -d "${SNAPDIR}" ]] && [[ "${RETAIN_SNAPSHOTS}" =~ ^[0-9]+$ ]]; then
  while IFS= read -r victim; do
    [[ -n "${victim}" ]] || continue
    rm -f "${victim}" 2>/dev/null || true
  done < <(find "${SNAPDIR}" -maxdepth 1 -type f -name '*.snapshot' -printf '%T@ %p\n' \
    2>/dev/null | sort -rn | tail -n +$(( RETAIN_SNAPSHOTS + 1 )) | cut -d' ' -f2- || true)
fi

# The dump: the version-portable fallback. Best effort on top of a good snapshot, so a failed dump
# is reported but does not undo the snapshot, which remains the primary restore artefact.
DUMP_NOTE="dump skipped (MEILISEARCH_BACKUP_DUMP=false)"
if [[ "${BACKUP_DUMP}" == true ]]; then
  DRESP="$(curl -fsS -m 60 -X POST "${ENDPOINT}/dumps" -H "Authorization: Bearer ${KEY}" 2>/dev/null || true)"
  DUID="$(printf '%s' "${DRESP}" | jq -r '.taskUid // empty' 2>/dev/null || true)"
  if [[ -z "${DUID}" ]]; then
    DUMP_NOTE="dump FAILED: POST /dumps did not return a task uid"
  else
    DSTATUS="$(poll_task "${DUID}")"
    if [[ "${DSTATUS}" == succeeded ]]; then
      DUMP_NOTE="dump task ${DUID} completed"
      if [[ -d "${DUMPDIR}" ]]; then
        while IFS= read -r victim; do
          [[ -n "${victim}" ]] && rm -f "${victim}" 2>/dev/null || true
        done < <(find "${DUMPDIR}" -maxdepth 1 -type f -name '*.dump' -printf '%T@ %p\n' 2>/dev/null \
          | sort -rn | tail -n +$(( RETAIN_DUMPS + 1 )) | cut -d' ' -f2- || true)
      fi
    else
      DUMP_NOTE="dump FAILED: task ${DUID} ended as ${DSTATUS}"
    fi
  fi
fi

case "${DUMP_NOTE}" in
  *FAILED*)
    record partial "snapshot task ${TASK_UID} completed; ${DUMP_NOTE}"
    printf '%s backup partly failed: the snapshot is good, but %s.\nRestores work; the version-portable fallback is missing. Details: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${DUMP_NOTE}" "${LOGFILE}" > "${FAILFILE}" 2>/dev/null || true ;;
  *)
    record succeeded "snapshot task ${TASK_UID} completed; ${DUMP_NOTE}"
    rm -f "${FAILFILE}" 2>/dev/null || true ;;
esac
exit 0
