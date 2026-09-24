### Meilisearch is running and ready

No setup wizard. Get your master key below, then point your apps or your own code at Meilisearch
whenever you want.

**Get your master key.** Open this app's Terminal (the `>_` button above) and run
`cat /app/data/master-key`. Send it as an `Authorization: Bearer <key>` header on every request.

**One route is public.** `GET /health` answers with no credential; it is what Cloudron itself
checks. Every other route, including `GET /version`, requires the master key or a key minted from
it.

**Mint a scoped key for each consumer**, rather than handing out the master key itself, with
`POST /keys`; see the README for a worked example. Revoke a scoped key at any time without
disturbing any other consumer.

**Test from your own computer:**

```
curl $CLOUDRON-APP-ORIGIN/health
curl $CLOUDRON-APP-ORIGIN/indexes -H "Authorization: Bearer PASTE-MASTER-KEY-HERE"
```

**Good to know.** The master key is generated once and never regenerated automatically: every key
Meilisearch issues afterwards is derived from it, so replacing it would silently invalidate every
key a consumer already holds. The full topology, the backup and restore design, and the wiring
recipes for LibreChat, Linkwarden, Strapi, and n8n are in the README and `docs/PACKAGING-NOTES.md`.

**Backups and restores.** Every backup takes a Meilisearch snapshot, plus a dump unless
`MEILISEARCH_BACKUP_DUMP=false` is set in `/app/data/env`. Restoring a backup rolls the search data
back to that snapshot; the previous live store is kept for 30 days in `/app/db/quarantine-<time>`.
If a backup could not take its snapshot, it still completes, so that the other apps on your server
are backed up, but it writes `/app/data/BACKUP-FAILED.txt`, and the app's log repeats that warning
at every start until a later backup succeeds.
