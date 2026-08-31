# Incident: the instance admin nobody configured — and nobody knew about

*Inherited from the originating instance (2026-08-04). A freshly bootstrapped
node stood on the public internet for several hours with an **active
IAM_OWNER account using the vendor's documented default password**. Nobody
noticed, because nobody knew the account existed.*

## What happened

A new instance was built strictly by `runbooks/bootstrap-from-zero.md`. Every
verify passed, TLS was real, Argo CD reported everything Synced/Healthy, and
identity work continued as documented. What none of the verifies looked at was
**who could log in as an instance administrator**.

There was such an account:

```
384785873810227230  zitadel-admin@zitadel.id.<domain>   human,   ACTIVE    IAM_OWNER
384785873810030622  iam-admin                           machine, INACTIVE  IAM_OWNER   (revoked in §5.4)
384785873810292766  login-client                        machine, ACTIVE    IAM_LOGIN_CLIENT
```

`zitadel-admin@zitadel.id.<domain>` had the password `Password1!` — which is
not a secret at all, it is printed in ZITADEL's own `cmd/setup/steps.yaml` and
in its documentation. The login form was reachable from anywhere.

It gets worse after the bootstrap finishes. §5.4 revokes `iam-admin` by
design, and the human the bootstrap creates via tofu (`admin.tf`) is only
**`ORG_OWNER`** — it administers the community org and gets `403` on
`/admin/v1/*`. So from the end of the bootstrap onward, this unknown account
was the **only** remaining route to instance level. The operator believed they
were the administrator of the system. At instance level, they were not.

## Root cause

`argocd/applications/zitadel.yaml` configures `FirstInstance.Org` with only a
`Machine` (`iam-admin`) and a `LoginClient` — **deliberately without a `Human`
block**, so that no plaintext password would ever sit in the repository. The
intent was correct. The inference drawn from it was not:

> "We did not configure a human admin, so no human admin exists."

ZITADEL does not treat an absent value as "skip". It falls back to its own
defaults and creates the user anyway:

| Upstream default (`cmd/setup/steps.yaml`) | Effect here |
|---|---|
| `Org.Name: ZITADEL` | org domain `zitadel.id.<domain>` |
| `Org.Human.UserName: zitadel-admin` | login `zitadel-admin@zitadel.id.<domain>` |
| `Org.Human.Password: Password1!` | the documented default password |
| `Org.Human.Email.Verified: true` | account immediately usable |
| (first org human) | **IAM_OWNER** on the instance |

`PasswordChangeRequired: true` is also a default, and it is **not** a
mitigation. It forces *the first person who logs in* to choose a new password.
Nothing says that person is you. On a public address it is a race, and whoever
wins it owns the instance — silently, because from ZITADEL's point of view
nothing abnormal happened.

Two failures compounded:

1. **Nothing enumerated the accounts.** The bootstrap verified pods, certs,
   Applications and DNS — every artefact *we* had written down. It never asked
   the instance who its administrators were.
2. **The revocation in §5.3 (now §5.4) ran unconditionally**, on the assumption
   that the tofu-created human was the administrator. `ORG_OWNER` ≠ `IAM_OWNER`.

## Symptom / diagnosis

There is no alert and no log line for this; you have to go look. The
authoritative answer is ZITADEL's own projection, readable straight from
Postgres — which is the point, because it works **without** any ZITADEL
credential, i.e. also after §5.4 (the ZITADEL image is distroless and has no
shell; the Postgres pod does):

```bash
PGPW=$(kubectl -n zitadel get secret zitadel-db-credentials \
  -o jsonpath='{.data.postgresPassword}' | base64 -d)
kubectl -n zitadel exec -i statefulset/zitadel-postgresql -- \
  env PGPASSWORD="$PGPW" psql -U postgres -d zitadel -At -F'|' -c "
    SELECT m.user_id, u.username,
           CASE u.type  WHEN 1 THEN 'human' WHEN 2 THEN 'machine' ELSE '?' END,
           CASE u.state WHEN 1 THEN 'active' WHEN 2 THEN 'inactive' ELSE '?' END,
           array_to_string(m.roles, ',')
      FROM projections.instance_members4 m
      JOIN projections.users14 u
        ON u.id = m.user_id AND u.instance_id = m.instance_id;"
```

With an IAM credential still in hand, `POST /admin/v1/members/_search` answers
the same question. Either way: **a human `IAM_OWNER` you cannot name is the
finding.**

## Immediate fix

1. Change that account's password **now** — same session, not "after the next
   step" (`POST /v2/users/<id>/password`).
2. Prove it with a **failed** login using `Password1!` against
   `POST /v2/sessions`, plus a positive control with the new password so a typo
   in the login name cannot fake a pass.
3. Give the account you actually use `IAM_OWNER` on the instance
   (`POST /admin/v1/members`), then deactivate the default account.

Full commands: `runbooks/bootstrap-from-zero.md` §5.2 and §5.4.0.

## Prevention (encoded in this template)

- **Invariant 9 in `AGENTS.md`:** no vendor default credential survives its
  bootstrap, not even briefly — and the obligation is to **enumerate the
  accounts that exist**, not to assume you know them. The general form of the
  lesson: *a configuration value you deliberately leave out does not produce
  nothing; it produces the vendor's default — and vendor defaults are
  published.* This applies to every chart in this stack, not just ZITADEL.
- **`bootstrap-from-zero.md` §5.2** is a mandatory step directly after the
  ZITADEL deploy: list the instance administrators (API, or Postgres when there
  is no credential), change the default password, and verify with a failed
  login. §4 ends with an explicit "do not pause here".
- **`bootstrap-from-zero.md` §5.4.0** gates the revocation of `iam-admin`
  behind a *verified* human `IAM_OWNER`, and spells out what `ORG_OWNER` cannot
  do (SMTP, login/password policies, instance-wide IdPs, further orgs, further
  instance admins).
- **§5.5** makes the administrator list part of the handover, and requires
  re-running it after every chart upgrade that re-runs a setup job.
- **CI asserts it** (`.github/workflows/e2e.yml`, "Smoke — no account accepts a
  vendor default password"): the harness boots a full stack, confirms the
  default admin exists, performs the §5.2 remediation, and then fails the build
  if `Password1!` still authenticates anywhere. A regression in the runbook —
  or an upstream change that reintroduces a default credential — breaks the
  build instead of a production instance.
