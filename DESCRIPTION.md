Meilisearch is an open source, typo-tolerant search engine written in Rust. It indexes your
documents and serves fast, relevant full-text search, filtering, and sorting over a simple REST
API, which makes it a building block for application search, site search, and chat or knowledge
base search, without the operational weight of a larger search platform.

This package runs Meilisearch on Cloudron as a headless search API, always in production mode:

- No dashboard, no single sign-on, and no interactive login screen sit in front of the API,
  because the application exists to serve programmatic clients, and a login wall would break every
  one of them.
- `GET /health` stays open with no credential, which is what the platform uses to judge whether
  the application is running. Every other route requires a master key, generated on first launch,
  or a scoped key minted from it.
- The Meilisearch data store is treated as the database it is: it lives on a Cloudron
  `persistentDirs` path so its constant background churn stays clear of the ordinary backup file
  walk, while a snapshot taken through the application's own API rides the regular backup, and is
  imported back automatically on a clone or a restore.

This is a community package. It tracks upstream Meilisearch releases and keeps the upstream binary
unmodified. Meilisearch and the Meilisearch name and logo are trademarks of their respective owner.
This package is community-maintained and is not affiliated with or endorsed by the Meilisearch
project.

Meilisearch itself is dual licensed (MIT for the core engine, Business Source License 1.1 for a
smaller enterprise edition subset). This package configures and runs only the MIT-licensed
community engine and enables no enterprise edition feature.
