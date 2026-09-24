# Tenant tokens

The tooling and most of this guide are james's, ported from his Cloudron package
(<https://git.cloudron.io/playground/meilisearch-app>, commit `45314aa`) with his agreement on the
Cloudron forum (topic 15761). The only changes are for this package's layout: the master key lives in
`/app/data/master-key`, and settings live in `/app/data/env`.

Some apps that use Meilisearch support [tenant tokens](https://www.meilisearch.com/blog/multi-tenancy).
Instead of the master key, they take a search-only API key and use it to sign short-lived tokens, so
each of their users can only search their own documents. Apps without tenant-token support keep using
the master key or a scoped key; nothing changes for them.

## Enable the signing key

Add this line to `/app/data/env` (File Manager or Web Terminal), then restart the app:

```bash
MEILISEARCH_TENANT_TOKEN_KEY=true
```

Once the server is healthy, the app creates a search-only API key named `Cloudron tenant tokens`
and writes it to `/app/data/tenant-token-signing-key.env` (mode 0600):

```bash
TENANT_TOKEN_API_KEY_UID=<uid>
TENANT_TOKEN_API_KEY=<key>
```

Enter the uid and key in the app that signs the tokens. That app decides what each of its users can
see, and Meilisearch enforces it on every search.

Setting it back to `false` and restarting deletes the key, which revokes every token signed with it.
Re-enabling creates a new key, so the old tokens stay invalid. The master key is never affected.

## One signing key per app

The packaged key covers all indexes. To give each app its own key, limited to its own indexes and
revocable on its own, create one in the Web Terminal:

```bash
meili-token.sh key-create "shop" --index products   # prints uid and key
meili-token.sh keys                                 # list signing keys
meili-token.sh key-delete <uid>                     # revoke that app's tokens
```

## Inspecting and signing tokens by hand

`meili-token.sh --help` in the Web Terminal lists every command. It is useful for checking what an
app's token can see, or for handing out a token manually:

```bash
meili-token.sh decode <token>                       # rules, expiry, and is the signing key still there?
meili-token.sh search <token> products shoes        # what this token finds
meili-token.sh create --index products --filter 'tenant_id = 42' --expires 7d
meili-token.sh create --key <uid> --index products --index articles --filter 'visibility = public'
```

`create` signs with the packaged key unless `--key` is given. Tokens expire after 24 hours unless
`--expires` says otherwise (`30m`, `12h`, `7d`, `4w`, a date, or `never`). A `--filter` only works on
fields the index lists in `filterableAttributes`. Tokens can only search, and cannot be revoked one
by one: let them expire, or delete the key that signed them.

## What the package tests

`test/smoke.sh` enables the key through `/app/data/env`, checks the key file is 0600 and absent from
the logs, and signs a token for one tenant. It then checks that the token sees that tenant's
documents and no one else's, and that other indexes refuse it. Finally it disables the key and
checks that the same token is refused.
