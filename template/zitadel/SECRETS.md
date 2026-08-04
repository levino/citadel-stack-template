# ZITADEL bootstrap secrets

Two secrets must exist before the `zitadel` Helm Application can start
(`argocd/applications/zitadel.yaml`):

| Secret | Content |
|---|---|
| `zitadel-masterkey` | 32-byte AES key for ZITADEL's internal encryption |
| `zitadel-db-credentials` | `postgresPassword` (Postgres superuser) + `password` (zitadel app user) |

These two are the **only** ZITADEL secrets that belong in git, and only as
SealedSecrets — never as plaintext (hard invariant, see `AGENTS.md`). They are
deployment data (the running instance cannot start without them) and carry no
personal data, so versioning them sealed is correct.

## What does NOT belong here (anti-patterns)

- **No ZITADEL API credential in git.** The credential used to manage identity
  content (a PAT, or a service-account key) is an **infrastructure
  credential**: passed per session, **never committed — not plaintext, not
  sealed** (invariants 3 + 6). Never seal an API credential into this
  directory.
  The `zitadel/iam-admin` secret that ZITADEL's setup job creates is **not**
  managed here and is not in git: the bootstrap reads it once for the tofu
  apply and then **deletes it** (`tofu/zitadel/README.md` step 4). Using it
  once is fine; leaving it in the cluster as a **standing** IAM-owner
  credential is the anti-pattern. See also
  `runbooks/zitadel-identity-via-api.md`.
- **No identity content.** Projects, roles, OIDC clients and — above all —
  user/group membership are managed at runtime via the ZITADEL API, never as
  sealed secrets or tofu state (GDPR; invariant 6).

## Procedure

Run from the repo root, with the cluster reachable (the sealed-secrets
controller must be running — it is part of `cluster/`):

```bash
./scripts/fetch-sealing-cert.sh     # writes sealed-secrets-public-key.pem
./scripts/seal-zitadel-secrets.sh   # writes zitadel/sealed-zitadel-*.yaml
git add sealed-secrets-public-key.pem zitadel/sealed-zitadel-*.yaml
git commit -m "Seal ZITADEL bootstrap secrets"
git push
```

Argo CD picks up the commit (or sync `zitadel-base` manually) and the
ZITADEL Applications turn Synced/Healthy.

With the public key in the repo, later secrets can be sealed **offline**
(`kubeseal --cert sealed-secrets-public-key.pem`) — no cluster access needed.
The controller decrypts with all historical keys, so a slightly stale public
key still works; refresh it periodically via `scripts/fetch-sealing-cert.sh`.

## Rotation

Re-run `scripts/seal-zitadel-secrets.sh` and commit. Note: rotating the
masterkey of a **running** instance is not supported by this script — it
generates fresh values and is meant for bootstrap. For an existing instance,
follow ZITADEL's masterkey rotation documentation.
