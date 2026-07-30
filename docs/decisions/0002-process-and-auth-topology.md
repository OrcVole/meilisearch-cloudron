# 0002: Single headless process, production mode, no proxyAuth

Status: accepted (health check behaviour to be verified empirically at Gate 1)

## Context

Meilisearch can run with or without a master key, and its `MEILI_ENV` setting can be
`development` or `production`. In development mode, or with no master key set, the API is
completely open and a built-in search preview UI is available. Meilisearch is, by design, a search
API meant to be called by other applications and by an operator's own code; a Cloudron package
that wrapped it in `proxyAuth`, the platform's single sign-on addon, would place an interactive
login redirect in front of every one of those programmatic callers, which cannot complete a
browser sign-in flow. That would break the entire point of installing the package. Equally, an API
with no master key at all is not an acceptable default for anything reachable on the wider
internet.

## Decision

Run a single process with no supervisor and no bundled reverse proxy: the container's `CMD` runs
`start.sh` (not yet written), whose last line execs `gosu cloudron:cloudron` into the Meilisearch
binary. `MEILI_ENV=production` is forced, always, with no configuration path to turn it off,
because the package is a headless API and never needs the development-mode preview UI. The
manifest declares `httpPort 7700` and the entrypoint sets `MEILI_HTTP_ADDR=0.0.0.0:7700`. No
`proxyAuth` addon is declared. Authentication is entirely Meilisearch's own master key mechanism
(ADR 0003). `healthCheckPath` is `/health`, the one route Meilisearch documents as staying
unauthenticated even with a master key set; this must be verified empirically, both with and
without a key configured, at the first gate ladder run, because documentation is a starting point
and the box is the authority. Addons are `localstorage` only; `MEILI_NO_ANALYTICS=true` is forced.

## Consequences

- Every route except `GET /health` requires a key, so an unauthenticated request from a stray
  client fails loudly with Meilisearch's own error rather than silently succeeding.
- The platform health check needs no credential, which keeps `cloudron status` and the dashboard
  health indicator working without any special-cased request.
- Because there is no `proxyAuth` and no dashboard, this package carries none of the two-surface
  topology complexity that a package with a bundled web UI would; there is exactly one surface,
  and it is uniformly key-protected apart from the one health route.
- This decision is unexercised at the scaffold phase: no image exists yet, so the exact behaviour
  of `/health` with and without a key, and the precise error body Meilisearch returns to an
  unauthenticated request, are both to be confirmed, not assumed, at Gate 1.
