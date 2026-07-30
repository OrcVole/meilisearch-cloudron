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

## History

**2026-07-30, entrypoint phase.** The auth topology is confirmed as designed; the process
topology needed one correction.

Confirmed empirically on a local container built from this package: `GET /health` answers 200
with no credential while a master key is set; `GET /version` and `POST /indexes/*/search` answer
401 with the documented `missing_authorization_header` body and 200 with the key; and `GET /` in
production mode returns `{"status":"Meilisearch is running"}` as `application/json`, with no HTML
and no search preview interface anywhere in the response.

**The correction is the last line of `start.sh`.** This record specified
`exec gosu cloudron:cloudron /app/code/meilisearch`, which makes Meilisearch PID 1. Meilisearch
installs no `SIGTERM` handler, and the kernel gives a process running as PID 1 no default signal
dispositions, so as PID 1 it ignores `SIGTERM` outright. Measured locally: a stop request was
ignored for the full 60 second grace period and the container was then `SIGKILL`ed. Every stop,
restart, update, and backup-triggered restart would have ended in an ungraceful kill of a
database process.

The line is therefore `exec /usr/bin/tini -- gosu cloudron:cloudron /app/code/meilisearch ...`.
`tini` is already present in `cloudron/base:5.0.0`, and upstream's own container image uses it as
its entrypoint for the same reason. With `tini` as PID 1 the same stop completes in 187ms with
exit code 143. This does not change the auth topology, the single-process design, or the drop to
the `cloudron` user; it changes only which process holds PID 1. The related signal problem inside
the supervised upgrade phase is recorded in ADR 0005.
