#!/bin/bash
#
# Cloudron restoreCommand for Meilisearch.
#
# The platform runs this in a temporary container after it has put the backup's /app/data back and
# before the app starts, on an in-place restore and on a clone. It does one thing: leave a flag in
# the persistent store directory saying "a restore happened", so that start.sh replaces the live
# store with the restored snapshot instead of carrying on with it.
#
# Why this is needed (field guide #311): /app/db is a persistentDir, and an in-place restore leaves
# it untouched, so without this the live store survived every restore and the user's search data was
# never rolled back. Gate 3 of 1.1.0 measured exactly that (260 000 documents in the backup,
# 1 000 000 after the restore) and scored it as a pass.
#
# The decision itself stays in start.sh, which already owns every other restore leg (ADR 0005):
# it rebuilds from the restored artefacts only when the backup actually carries one, and keeps the
# live store, loudly, when it does not. This script only records that a restore happened, because
# start.sh cannot tell an in-place restore from an ordinary restart by itself.
#
# It exits non-zero if the flag cannot be written. A restore that cannot be honoured should fail
# where the operator sees it, not quietly become a restart that rolls nothing back.

set -u
FLAG=/app/db/.restore-pending

if ! printf 'restore requested %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${FLAG}"; then
  echo "restore-flag: could not write ${FLAG}; the search store would not be rolled back" >&2
  exit 1
fi
exit 0
