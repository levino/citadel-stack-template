# Incident: Argo CD too old for the cluster — Applications stop reconciling

*Hit on the first real bootstrap of a derivative (fresh Debian 13 server, k3s
`v1.36.2+k3s1`). CI never saw it — see "Why CI missed this" below.*

## What happened

The bootstrap runbook pinned Argo CD `v2.13.3` (§2). Everything came up, every
pod was `Running`, and `kubectl -n argocd get applications` looked almost
right — except one Application sat at:

```
NAME    SYNC STATUS   HEALTH STATUS
<app>   Unknown       Healthy
```

`Healthy` is the column people read, so the cluster looked fine. It was not:
that Application had **stopped reconciling**. Commits pushed to the repo were
silently never applied, and self-healing was dead — a drifted or deleted
resource would not have been restored.

## Root cause

Argo CD computes diffs with a *structured merge* against the live resource,
which requires the live object to validate against the schema the Argo binary
was built with. k3s `v1.36.2+k3s1` serves a `Deployment` status field
(`.status.terminatingReplicas`) that Argo CD `v2.13.3` does not know, so the
diff calculation aborts before any comparison happens:

```
Failed to compare desired state to live state: failed to calculate diff:
error calculating structured merge diff: error building typed value from live
resource: .status.terminatingReplicas: field not declared in schema
```

Sync status therefore degrades to `Unknown` while health — computed from the
live resource alone, not from a diff — stays `Healthy`. **A GitOps controller
that cannot diff is a GitOps controller that is off**, and this failure mode
does not announce itself.

The general rule: Argo CD must never be *older* than the Kubernetes API it
reconciles against. Pinning an Argo CD version in a runbook that is used months
later on a freshly installed k3s guarantees this skew eventually.

## Symptom / diagnosis

```bash
kubectl -n argocd get applications          # SYNC Unknown, HEALTH Healthy
kubectl -n argocd get app <name> -o jsonpath='{.status.conditions}'
# → ComparisonError: ... field not declared in schema
kubectl -n argocd get deploy argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl version -o json | jq -r .serverVersion.gitVersion
```

Any `ComparisonError` mentioning `not declared in schema` is this incident.

## Immediate fix

Upgrade Argo CD (verified: `v2.13.3` → `v3.4.6` on k3s `v1.36.2+k3s1`; the
affected Application went `Synced/Healthy` within one reconcile, no restart or
manual sync needed).

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.6/manifests/install.yaml

# install.yaml SHIPS argocd-cm — the two bootstrap patches are now gone.
# Re-apply them or you have silently re-introduced both traps from
# runbooks/incidents/argocd-resource-tracking.md.
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{
  "application.resourceTrackingMethod":"annotation",
  "resource.customizations.health.networking.k8s.io_Ingress":"hs = {} hs.status = \"Healthy\" hs.message = \"single-node hostPort Traefik publishes no load-balancer status\" return hs"
}}'
kubectl -n argocd rollout restart statefulset/argocd-application-controller
kubectl -n argocd get applications          # all Synced/Healthy
```

## Why CI missed this

`.github/workflows/e2e.yml` boots the cluster with **k3d**, and k3d's default
image is a k3s release well behind what `curl -sfL https://get.k3s.io | sh -`
installs on a fresh server today. CI therefore exercised an old Argo CD against
an old Kubernetes — a combination that works — while the runbook produced an
old Argo CD against a brand-new Kubernetes on the first real server.

Any pin that CI holds constant but reality moves forward is this bug class.

## Prevention (encoded in this template)

- The bootstrap runbook no longer hard-pins an old release: §2 installs
  `ARGOCD_VERSION=stable`, marked as a reviewed value, with the rule that a
  pinned tag must be **newer** than the cluster's Kubernetes version, never
  older.
- §2's verify prints the Argo CD image next to the cluster version; §3's verify
  calls out `SYNC: Unknown` + `HEALTH: Healthy` explicitly as a failure, not a
  transient state — never read the health column alone.
- After every `install.yaml` apply (install *or* upgrade), re-apply the
  `argocd-cm` patches — `install.yaml` contains that ConfigMap.
- CI should run the e2e matrix against a current k3s image, not only k3d's
  default, so version-skew regressions fail in CI instead of on a first
  bootstrap.
