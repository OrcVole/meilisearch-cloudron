# Changelog

[1.0.0]
- Initial release. Packages Meilisearch 1.51.0 on cloudron/base:5.0.0, with the upstream release
  binary and meilitool pinned by sha256 and left unmodified.
- Headless search API in production mode: no dashboard, no single sign-on, no proxy authentication.
  GET /health is the one route that stays open, which is what Cloudron's health check uses; every
  other route requires the master key or a key minted from it.
- The master key is generated once on first start, stored at /app/data/master-key, and never
  regenerated, because every key Meilisearch issues afterwards is derived from it.
- Database-class backup design: the Meilisearch data store lives on a persistentDirs path
  (/app/db), out of the ordinary backup file walk, while a backupCommand asks the live instance
  over its own API for a consistent snapshot into /app/data. Backup while idle, backup under heavy
  indexing churn, in-place restore, clone, rollback restore, and dump import are all exercised.
- The entrypoint distinguishes a fresh install, a clone, an in-place restore, a rollback restore
  and a version-mismatched store, and imports the newest snapshot or dump, or runs a supervised
  --upgrade-db migration, as appropriate.
- MEILI_MAX_INDEXING_MEMORY is computed from the cgroup limit on every boot, because Meilisearch
  otherwise sizes its indexing buffers from host-visible RAM rather than the container limit.
- memoryLimit is 4 GB, set from a measured anonymous-memory peak while indexing one million
  documents, not from a guess.
- Analytics are disabled unconditionally. Operator overrides live in /app/data/env.
