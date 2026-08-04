# agentops-community-stack

> **Status: v1 — production-ready.** The template is complete and works: every
> pull request generates a fresh derivative and boots the *whole* substrate
> (k3s + Traefik, cert-manager, sealed-secrets, Argo CD, ZITADEL, real ACME via
> Pebble, `tofu apply`) end to end, green, on both `amd64` and `arm64`. Generate
> your community's stack today — see [§6](#6-distribution--usage). v1 is stable
> and meant to be used; it keeps evolving through the feedback loop in §7.

An **agent-operable GitOps stack with central single sign-on**, designed as a
reusable template for communities, clubs, and small organizations that want to
run a zoo of web applications on cheap infrastructure — with *one* identity per
person across all applications.

Distilled from a real, running setup (`levino/server-config`) that manages a
growing collection of privately deployed apps on a single Hetzner server. This
template extracts the *pattern*, detached from the concrete instance.

---

## 1. What this is for

Three things at once that are usually solved separately:

1. **Deployment** — apps land on a k3s cluster via GitOps. Push to `main`
   → automatic rollout. No stored cluster secrets, no manual `kubectl`.
2. **Identity** — one central identity provider (ZITADEL). Every person has
   *one* account and uses it across any number of subgroups/clubs. Delegated
   administration: a club's board manages its own members in self-service,
   without access to anything else.
3. **Agent operability** — the entire stack is documented and structured so
   that an AI can build and operate it from zero: read/write git, open PRs,
   debug CI, run `kubectl`, check certificates. The human is product owner,
   not operator.

The distinctive point is **(3)**: not just infrastructure-as-code, but
*infrastructure-as-code-that-an-agent-can-reliably-rebuild*. That is what makes
the stack templatable — and it is the actual subject of this repo.

---

## 2. The stack (the substrate)

```
Internet :80/:443
  └── k3s + Traefik (hostPort)
        ├── cert-manager        → automatic Let's Encrypt certificates
        ├── sealed-secrets      → secrets encrypted in git
        ├── Argo CD             → GitOps reconciler (repo = truth) + PR previews
        ├── ZITADEL             → central OIDC provider (id.<domain>)
        └── your apps           → one namespace each, one OIDC client each
```

| Building block | Role | Why |
|---|---|---|
| **k3s** | single-node Kubernetes | lightweight, runs on cheap infra |
| **Traefik** | ingress + TLS termination | ships with k3s, ForwardAuth-capable |
| **cert-manager** | TLS automation | Let's Encrypt without manual work |
| **sealed-secrets** | secrets in git | encryptable offline against a public key |
| **Argo CD** | GitOps reconciler | the repo is the single source of truth; native PR previews (ApplicationSet) |
| **ZITADEL** | identity provider | org/project/role + delegated admins + self-service |
| **OpenTofu** | identity as code | orgs, projects, OIDC clients declaratively |
| **GitHub Actions + OIDC** | deploy pipeline | no stored kubeconfig secret |

**Deliberate limits:** single node, single replica. No HA. That is a *feature*
of "cheap infra", not a defect — and it is named honestly as such.

---

## 3. Two layers — two propagation mechanisms

The most common design mistake: trying to distribute everything through *one*
mechanism. These are two different frequencies:

| Layer | Frequency | Mechanism |
|---|---|---|
| **Cluster substrate** (k3s, Traefik, cert-manager, sealed-secrets, Argo CD, ZITADEL) | **once per community** | Copier — generate once, keep current via `copier update` |
| **Per-app pattern** (namespace, Argo CD Application, PR-preview ApplicationSet, OIDC client) | **many times within the same cluster** | in-repo generator (`scripts/new-app.sh` / skill) inside the generated repo |

Copier is for "new community from zero". The in-repo generator is for "the 20th
app in the same cluster". Both belong in the template, but they solve different
problems.

---

## 4. Authentication: two patterns, both supported

Not an either/or. They solve different problems:

| | **Native OIDC** | **ForwardAuth** (oauth2-proxy as Traefik middleware) |
|---|---|---|
| For | apps you **build yourself**, where you need *who + which role* | third-party apps that **cannot do their own auth** (dashboards, internal tools, "members only" pages) |
| The app gets | real ID/access tokens, claims, refresh, clean logout | headers only (`X-Forwarded-User/-Groups`) |
| Authorization | fine-grained, per resource, based on role claims | coarse (logged in? in group X?) |
| Setup | one OIDC client per app via OpenTofu | one oauth2-proxy instance + reusable middleware, enabled per ingress annotation |

For fine-grained club authorization ("who is on the board, who may access
what"), **native OIDC** is the way. **ForwardAuth** is the convenient front door
for everything that does not speak OIDC. The template ships both as documented,
copyable recipes.

---

## 5. The identity model for communities (the centerpiece)

ZITADEL primitives: **Organization → Project → Role**, plus **user grants** (a
user receives a role in a project) and **managers** (delegated admins).

**Recommended model for a village/community instance:**

> **One org = the community** (e.g. "Rössing") = the shared identity pool.
> **Each club / subgroup = one project.**
> **Each board = project manager of its project.**

```
Org "Rössing"  (all people, created once)
 ├── Project "sports-club"      roles: member, board, treasurer
 │     └── Manager: sports club board  ← self-service for its own members
 ├── Project "village-care"     roles: member, lead
 ├── Project "civic-foundation" roles: member, board, trustees
 └── Project "village-internal" roles: resident, council
```

- **One identity, usable everywhere.** One person, one account — active in the
  sports club, village care, and the civic foundation at the same time.
- **Self-service with delegation.** The sports club board is project manager
  and assigns existing village users to its club roles — no new accounts, no
  access to other clubs.
- **Roles end up as claims in the token** → each app authorizes on them.

**Two honest limits, so nobody runs into a wall:**

1. **ZITADEL has no deep "groups in groups" hierarchy** like LDAP OUs. There is
   org → project → role. Deeper structures (club → division → board) are
   modeled via **role conventions** (`football:board`) or ZITADEL **Actions**
   that compute derived claims. Plan flat, not as a tree.
2. **ZITADEL is an IdP, not a club-management CRM.** Identity + login + coarse
   roles belong in ZITADEL. Rich club data (fees, join dates, membership
   numbers, events) lives in app databases (e.g. PocketBase), linked via the
   ZITADEL `sub` as a foreign key.

All of this ships as a **reusable OpenTofu module**: a new community
instantiates it by listing its clubs + roles.

*(There is an alternative model — "every club its own org" — with more
isolation and per-club branding, but then "one identity everywhere" only works
via project grants/federation. Overkill for a village; not recommended.)*

---

## 6. Distribution & usage

### Not the GitHub "Use this template" button

The button copies files **verbatim** (domain/IP/org would have to be replaced
by hand) and **severs every connection** to the template (no history, no update
path). "Promoting patterns back upstream" would be structurally impossible. The
template flag may be set (discoverability), but it is not the generation
mechanism.

### Instead: Copier

[Copier](https://copier.readthedocs.io/) is a CLI tool (nothing is "hosted" —
it runs locally, in CI, or inside an agent). The **template repo** is an
ordinary GitHub repo; the **generated repo** lands in the user's account.

```bash
# A community generates its infra stack — needs nothing but uvx:
uvx copier copy gh:levino/agentops-community-stack ./my-infra
  # → Copier asks: domain? server IP? org name? which clubs? registry? …
  # → produces ./my-infra with everything filled in (Jinja placeholders)

cd my-infra && git init && git add -A && git commit -m "init" && git push
```

From here an **agent** takes over, guided by the bundled `AGENTS.md`: it reads
the invariants + the bootstrap runbook and brings up k3s/Argo CD/ZITADEL. That
is the "tell the agent: rebuild this for me" flow.

Updates later:

```bash
cd my-infra && uvx copier update   # merge template fixes into the existing project
```

Copier records the template version in `.copier-answers.yml` → `update` is a
targeted merge of the template changes since then (conflicts as in a rebase,
but that is exactly the point).

---

## 7. The feedback loop (both directions)

```
        ┌──────────────────────────┐
        │ agentops-community-stack │  ← the truth
        └───────────┬──────────────┘
   copier update    │   PR "promote learning"
   (automatic)      │   (human/agent judgment)
        ┌───────────▼──────────────┐
        │  roessing/infra, …others │  ← derivatives
        └──────────────────────────┘
```

- **Template → derivatives** (improvements flow down): `copier update`.
  Automatable.
- **Derivative → template** (a lesson becomes canon): **a normal PR against the
  template repo**. Deliberately *not* automatic — not every local hack should
  become canon. Discipline: footgun → write an incident in the derivative → PR
  that lifts the *generalizable* part into the template (runbook / incident /
  guardrail).

**Harden knowledge instead of merely documenting it:** wherever possible,
hard-won lessons become *enforced* guardrails rather than prose — e.g. a
Kyverno/OPA policy that *forbids* `cluster-admin` bindings for CI identities,
instead of a doc that merely warns about them.

---

## 8. Continuous validation in CI (the primary test harness)

The template is not "done" when the files exist — it is done when a generated
derivative comes up green, automatically, on every PR. **It does.** The whole
substrate is containerizable, so the main validation loop runs in GitHub
Actions on every change:

1. **Generate** a throwaway derivative via `uvx copier copy` with a CI answers
   file. This alone catches broken Jinja and invalid YAML after substitution.
2. **Boot** the cluster with **k3d** (k3s in Docker — including the bundled
   Traefik, so fidelity is high).
3. **Reconcile** the generated repo with Argo CD (install Argo CD, apply the
   root "app of apps", wait for every `Application` to go Synced/Healthy).
4. **TLS via Pebble**, Let's Encrypt's purpose-built test ACME server, deployed
   in-cluster and set as cert-manager's issuer. This exercises the real ACME
   machinery (order, HTTP-01 challenge, solver routing through Traefik). Tests
   trust Pebble's root CA explicitly (`curl --cacert`). Consequence: the
   **issuer must be a parameter/overlay**, never hardcoded — `letsencrypt-prod`
   in real derivatives, `pebble` in CI.
5. **Smoke tests:** ZITADEL's OIDC discovery endpoint answers over HTTPS, the
   ForwardAuth pattern redirects an unauthenticated request, an app namespace
   deploys via the per-app pattern, the `cluster-admin` guardrail actually
   denies a forbidden binding, etc.

Useful side effects:

- **sealed-secrets workflow tested on every run:** CI seals fresh dummy secrets
  against the CI controller's freshly generated key — validating the sealing
  procedure itself (historically the biggest bootstrap hurdle).
- **ARM64 enforced, not just claimed:** public repos get free
  `ubuntu-24.04-arm` runners, so the e2e matrix runs on both architectures and
  enforces the multi-arch invariant.
- **Incidents become executable:** every reproducible footgun from the
  originating instance becomes an assertion in the suite —
  incidents-as-regression-suite, literally.
- **`copier update` stays clean:** a dedicated job generates a derivative from
  the previous template revision, runs `copier update` to HEAD, and fails on
  any conflict marker — so template improvements keep merging into existing
  derivatives without hand-patching (§6).
- **Guardrails are enforced, not just documented:** the `cluster-admin` policy
  (invariant #1) is exercised — CI asserts a forbidden binding is rejected at
  admission time.
- **Vendor defaults cannot survive a bootstrap:** CI enumerates the ZITADEL
  *instance* administrators, performs the runbook's remediation, and then fails
  the build if any of them still authenticates with a documented default
  password (`Password1!` & co.). A regression in the runbook — or an upstream
  change that reintroduces a default credential — breaks the build instead of a
  production instance (`runbooks/incidents/zitadel-default-admin.md`).

**What CI honestly cannot cover:** the `curl | sh` k3s install itself, systemd
configuration, hostPort binding on a real NIC, real DNS + Let's Encrypt rate
limits. That residue is small, and it is exactly what
`runbooks/bootstrap-from-zero.md` walks through — every step paired with a
verify command — when you bring up a real node.

---

## 9. Repo layout

```
agentops-community-stack/
├── README.md                  # this document (vision + usage)
├── copier.yml                 # template questions (domain, IP, org, clubs, …)
├── .github/workflows/e2e.yml  # CI harness: generate → k3d → Argo CD → Pebble → smoke tests
├── tests/
│   └── answers-ci.yml         # Copier answers for the CI-generated derivative
└── template/                  # ← Copier _subdirectory: everything below is generated
    ├── AGENTS.md.jinja        # agent contract: invariants + runbooks (see below)
    ├── argocd/                # GitOps entry point: AppProject + root "app of apps" + child Applications
    ├── cluster/               # substrate: cert-manager, sealed-secrets, rbac, policy
    ├── tofu/zitadel/          # identity as code
    │   └── modules/community/ # reusable "org = community, project = club" module
    ├── patterns/              # copyable recipes
    │   ├── app-native-oidc/   # app as OIDC client
    │   └── app-forwardauth/   # third-party app behind oauth2-proxy
    ├── scripts/
    │   └── new-app.sh         # in-repo generator (layer 2)
    └── runbooks/
        ├── bootstrap-from-zero.md # top to bottom, every step with a verify command
        └── incidents/             # regression "test suite" of known footguns
```

Note the `template/` subdirectory (Copier's `_subdirectory`): it separates the
template's own repo machinery (CI harness, tests, this README) from what gets
generated into a derivative.

**Key insight:** what makes the stack agent-operable is not the YAML — it is
the **prose** (`AGENTS.md`, `runbooks/`, `incidents/`). A rebuilding agent
stands or falls with it. The `incidents/` are effectively the regression test
suite: every documented footgun is a mistake the next agent must not repeat.

---

## 10. Invariants (the hard rules)

These apply to every instance and every agent that touches the stack:

- **Never `cluster-admin` for CI/OIDC identities.** Namespace-scoped RBAC from
  day one — *enforced* by an admission policy in `cluster/policy/`, not left to
  discipline.
- **GitOps is the single source of truth.** No manual `kubectl apply` outside
  documented bootstrap steps.
- **Secrets only as sealed-secrets in git.** Never commit plaintext secrets.
- **No vendor default credential survives its bootstrap** — and the obligation
  is to *enumerate the accounts that exist*, not to assume you know them. An
  omitted configuration value does not produce nothing; it produces the
  vendor's default, and vendor defaults are published. Asserted in CI.
- **Build multi-arch** when the target node is ARM64.
- **ZITADEL = IdP, not CRM.** Domain data belongs in app databases.
- **Identity is declarative** (OpenTofu), not UI clicks.

---

## 11. Deliberately NOT in the template

- Coolify passthrough / migration leftovers (instance-specific).
- Concrete domains, IPs, org names (they come from `copier.yml`).
- HA / multi-node (different cost profile — its own template, if ever needed).

---

## 12. Design decisions (why it is the way it is)

- **Blessed deploy path: the app owns its `deploy/` overlay**; the infra repo
  only registers it (`scripts/new-app.sh <name> --repo <url>`). An in-repo mode
  exists for third-party apps that have no repo of their own.
- **ZITADEL OpenTofu runs locally** for real derivatives (the template's CI
  exercises `tofu apply` end to end anyway).
- **Secret bootstrap is scripted:** `scripts/fetch-sealing-cert.sh` +
  `scripts/seal-zitadel-secrets.sh` — and CI runs both on every PR (§8).
- **Guardrails are policy, not prose:** the `cluster-admin` invariant is a
  ValidatingAdmissionPolicy (`cluster/policy/`), and `copier update` cleanliness
  is a CI job — both verified on every PR (§8). New lessons follow the same
  path: harden into an enforced check, not a doc that merely warns (§7).

The stack keeps evolving through the feedback loop in §7 — real-world lessons
become canon by PR, and derivatives pull them in with `copier update`.

---

## Origin

Distilled from `levino/server-config` — a real, running single-node stack. Its
`incidents/` and runbooks are the experience base of this template.
