# 0003: The master key, generated once, never regenerated

Status: accepted (idempotent generation and the stop condition to be verified at the start.sh phase)

## Context

Meilisearch derives every API key it hands out, including the automatically created default search
and admin keys and any scoped key an operator mints afterwards through `POST /keys`, from a single
master key. This is fundamentally different from a service where each credential is independent:
regenerating the master key does not just add a new credential, it silently invalidates every key
already issued, including ones held by consumers such as LibreChat that may not be watched closely
enough to notice a sudden authentication failure. A package that regenerated the master key on
every restart, or on an update, would be quietly hostile to its own consumers.

## Decision

On first run, when neither `/app/data/master-key` nor an existing data store is present, generate
the key with `openssl rand -hex 32`, write it to `/app/data/master-key`, and set its mode to 0600,
owned by `cloudron`. Never regenerate it once it exists. If `data.ms` exists under `/app/db` but
the master key file is missing, the entrypoint (not yet written) must stop with a loud, clearly
labelled error rather than generate a replacement key, because generating a new key in that
situation would silently orphan every consumer's existing key against a data store that expects
the old one. Ownership and file mode are re-asserted on every boot, not only on first run, because
a restore can reset them. The operator reads the key through the file manager or `cloudron exec`;
`postInstallMessage` and `POSTINSTALL.md` state exactly how, and how to mint a scoped key rather
than distributing the master key itself to every consumer. An optional package environment file at
`/app/data/env`, sourced at boot, is the intended path for operator overrides such as log level or
an indexing memory override; its supported variable names are to be documented in the README once
the entrypoint exists.

## Consequences

- Every consumer's key keeps working across a restart, an update, and a restore, provided the data
  store and the master key file travel together, which the data layout in ADR 0004 is designed to
  guarantee.
- A missing master key next to an existing data store is a hard stop, not a silent regeneration,
  which trades a small amount of first-boot friction after an unusual failure for the certainty
  that a key is never invalidated without the operator's knowledge.
- This decision is unexercised at the scaffold phase: the generation step, the idempotency check,
  the stop condition, and the mode and ownership re-assertion on every boot are all to be written
  and proven, not assumed, once `start.sh` exists.
