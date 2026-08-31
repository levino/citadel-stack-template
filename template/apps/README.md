# apps/ — one entry per application

Apps are stamped out with `scripts/new-app.sh` — never by hand-copying YAML.

Two kinds of apps, two shapes:

## 1. Own apps (blessed path): the app owns its `deploy/` overlay

The app's repository contains its manifests (e.g.
`deploy/overlays/production`); this repo only **registers** it:

```bash
./scripts/new-app.sh myapp --repo https://github.com/OWNER/myapp
```

This creates `apps/myapp.yaml` (the namespace + an Argo CD `Application` that
pulls the app repo's `deploy/overlays/production`) and, unless you pass
`--no-previews`, `apps/myapp-previews.yaml` (an `ApplicationSet` PullRequest
generator — one live environment per open PR, auto-pruned on close; see
`patterns/app-preview-prs/`). Rollout = push to the app repo's `main`.

Everything is **pull-based**: Argo CD reads the repo, so the app's CI never
needs cluster credentials. If the app needs login, give it its own OIDC client:
see `patterns/app-native-oidc/`.

## 2. Third-party / static apps: manifests live here

For software you do not develop (dashboards, internal tools):

```bash
./scripts/new-app.sh grafana --domain grafana.example.org --image grafana/grafana --port 3000
```

This creates `apps/grafana/` with namespace, deployment, service and ingress
(TLS via the `acme` ClusterIssuer). Add `--protected` to put it behind the
central login (ForwardAuth — requires `patterns/app-forwardauth/` to be
deployed once).

## Rules

- One namespace per app (one per PR for previews). If an app's CI ever needs
  push access, it gets the `preview-deployer` role in its namespace only —
  never `cluster-admin`.
- Images must be built for the server architecture (multi-arch builds).
- An app whose image is **private** (every app that bakes protected content
  into its build — see `patterns/app-deploy-ci/`) needs the `ghcr-pull`
  `imagePullSecret` in its namespace and an `imagePullSecrets:` block in its
  Deployment: `runbooks/bootstrap-from-zero.md` §7. Never make a package public
  to make a pull work.
- Only **app/service secrets** enter this repo, and only as SealedSecrets.
  **Infrastructure credentials** (Argo CD GitHub App key, ZITADEL operator
  credential, the registry pull credential) live only in the cluster — never
  committed, not even sealed (AGENTS.md inv. 3;
  `runbooks/argocd-github-app.md`).
