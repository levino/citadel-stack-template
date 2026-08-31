# tofu/zitadel — ZITADEL bootstrap (instance/org only)

> **Identity CONTENT is NOT managed here.** Projects, roles, OIDC clients,
> external IdPs and — above all — **who is in which group/role (user grants)**
> are managed through the **ZITADEL API at runtime**, never in tofu/git
> (invariant 6, `AGENTS.md`). This directory is, at most, the **bare
> instance/org bootstrap**. The day-to-day identity work lives in
> `runbooks/zitadel-identity-via-api.md` and `patterns/`.

## Why content is not code (read before "improving" this)

1. **GDPR.** Membership and role grants are personal data about real people.
   In version control they are practically impossible to delete (history,
   forks, clones, CI caches, tofu state) — exactly what data-protection law
   forbids for personal data. It must therefore never enter git.
2. **Churn.** Members join and leave, roles change weekly. A code-review loop
   for every grant is the wrong tool; the ZITADEL console/API is the right one.

So tofu here is intentionally tiny and **run once**: enough to stand the
instance and org up so a human admin can log in and take over via the console
and the API. Everything after that is API/console work, documented as
runbooks, not committed as state.

## The API credential — used once, never standing

The provider credential is an **infrastructure credential** (invariants 3 + 6):

- **never** committed — not plaintext, not sealed;
- **never** left in the cluster or on disk as a **standing** credential.

What the invariant governs is **persistence, not usage**. ZITADEL's setup job
creates the machine user `iam-admin` and stores its JWT profile as the k8s
secret `zitadel/iam-admin`; the provider authenticates with `jwt_profile_file`
(`main.tf`). Reading that secret **once** for the bootstrap apply and revoking
it immediately afterwards is the documented path — it satisfies the invariant
more strictly than a hand-minted PAT, which typically stays valid until someone
remembers to delete it.

> **Anti-pattern (do not):** *parking* the `iam-admin` key on disk or in the
> cluster as the permanent provider credential — a standing IAM-owner key that
> outlives the bootstrap. Revocation (step 4 below) is part of the procedure,
> not an optional tidy-up.

This also removes the last human step from a bootstrap: the whole stack comes
up without anyone logging into a console, which is the point of this template.

Trade-off, accepted and documented: after revocation the API credential is not
reproducible from git. A later `tofu apply` needs a fresh credential — a new
`iam-admin` key from a re-run setup job, or an operator PAT minted by hand.
That is the correct cost of keeping standing admin credentials out of the repo.

## Bootstrap (once, after the first ZITADEL deploy)

ZITADEL must be running (`kubectl -n argocd get app zitadel` →
Synced/Healthy). Fully scriptable, no console step:

1. Create the state namespace (once):

   ```bash
   kubectl create namespace terraform-state
   ```

2. Take the credential out for this session (gitignored, mode 600 — never
   committed, never copied elsewhere):

   ```bash
   umask 077
   kubectl -n zitadel get secret iam-admin \
     -o jsonpath='{.data.iam-admin\.json}' | base64 -d > service-user.json
   chmod 600 service-user.json
   jq -re '.userId, .keyId' service-user.json   # verify: both non-empty
   ```

3. **Inventory the instance administrators and remove the vendor default —
   before anything else.** The ZITADEL setup job also creates a *human*
   `IAM_OWNER` you never configured: `zitadel-admin@zitadel.<domain>` with the
   documented default password `Password1!` (omitting `FirstInstance.Org.Human`
   yields the vendor's default, not "no user"). List the instance members,
   change that password immediately, and prove it with a **failed** login using
   the old value: `runbooks/bootstrap-from-zero.md` §5.2,
   `runbooks/incidents/zitadel-default-admin.md`, `AGENTS.md` invariant 9.

4. Apply the bootstrap:

   ```bash
   tofu init
   tofu plan
   tofu apply
   ```

   This creates **structure only** — the org, one project per association, the
   roles those projects assert, and the ForwardAuth OIDC client. It creates no
   people; see the note at the top of this file.

5. **Create your human administrator by hand — before step 6.** Nothing in this
   directory does it for you any more. Create the account in the ZITADEL console
   (or via the API with the bootstrap credential), set a password you actually
   hold, then grant it `IAM_OWNER` at instance level. `ORG_OWNER` is not enough:
   it gets `403` on `/admin/v1/*`, so no SMTP provider, no instance
   login/password policy, no instance-wide external IdP, no further orgs, no
   further instance admins.

   ```bash
   USER_ID='…'   # the account you just created and logged into
   curl -fsS -X POST "https://id.<domain>/admin/v1/members" \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d "$(jq -n --arg u "$USER_ID" '{userId:$u,roles:["IAM_OWNER"]}')"
   ```

   Full procedure with the verification: `runbooks/bootstrap-from-zero.md` §5.3.

6. **Revoke the credential — mandatory, and in this order:** first confirm that
   a **human** `IAM_OWNER` exists whose (non-default) password you actually
   hold and have just tested — revoking before that cuts the instance level off
   entirely, and you only find out weeks later. Then revoke the key and
   deactivate the machine user via the API, **prove the revocation worked while
   you still hold the key** (request a token with the JWT profile again — it
   must fail), and only then destroy the key material (file +
   `zitadel/iam-admin` secret). Full commands, including the precondition gate
   and the `urn:ietf:params:oauth:grant-type:jwt-bearer` negative test:
   `runbooks/bootstrap-from-zero.md` §5.4.

   Do not shorten this to "delete the file and the secret". The API answering
   HTTP 200 twice is not evidence that the credential is dead, and once the
   profile is gone you can never test it: a revocation that silently did not
   take leaves a valid IAM-owner credential in the instance with nobody
   watching. A later chart upgrade re-runs the setup job and may recreate
   `zitadel/iam-admin` — check after every ZITADEL upgrade and delete it again.

**Alternative (rebuild case):** if the secret no longer exists and no setup job
will recreate it, mint an operator service-user PAT by hand instead — console →
Instance → Service Users → create → IAM-owner manager role → generate a
**Personal Access Token** — and pass it per session via `ZITADEL_TOKEN`
(the provider accepts it in place of `jwt_profile_file`), then delete the PAT
in the console when done. Same rule: used per session, never stored.

From here, log in at `https://id.{{ domain }}` as `admin` and do all further
identity work through the console / API (`runbooks/zitadel-identity-via-api.md`).

## State

Backend: `kubernetes` secret in namespace `terraform-state`. Access requires
cluster access — the same trust boundary as `kubectl`. Because content lives
in the API and not in tofu, the state stays small and contains **no personal
membership data**. It may still contain the bootstrap admin's initial password
output; treat it as sensitive.

## What is (and is not) managed here

Managed (bootstrap only):

- the org = the community (the shared identity pool)
- the first admin user as `ORG_OWNER` (`admin.tf`) — the human who then takes
  over via the console. **`ORG_OWNER` is org level only**; the instance-level
  `IAM_OWNER` grant is a deliberate API step (step 5 above), because a member
  role is identity *content* and does not belong in tofu state (invariant 6).

**Not** managed here (API/console at runtime — invariant 6):

- projects, roles, OIDC clients
- user grants / who is in which group or role
- external IdPs (Google etc.) and login policy — see
  `patterns/zitadel-login-v2/` and `patterns/zitadel-external-idp/`

For an app that needs its own OIDC client or role claims, create the client
via the API/console and wire the credentials in as a SealedSecret next to the
app — recipe in `patterns/app-native-oidc/`.
