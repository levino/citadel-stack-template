# incidents/ — the regression suite in prose

Every reproducible footgun gets a file here: what happened, root cause,
fix, prevention. A rebuilding agent reads these BEFORE debugging — each
documented incident is a mistake the next agent must not repeat.

Convention: `YYYY-MM-DD-<slug>.md` with sections **What happened**,
**Root cause**, **Fix**, **Prevention**. Write it the day it happens.

Incidents that ship with the template (general, not instance-specific):

- `disk-pressure.md` — uncleaned PR previews filled the disk; the whole
  single-node cluster went down.
- `zitadel-bootstrap.md` — six distinct traps when bringing up
  ZITADEL/Postgres via Helm. The template already encodes the fixes; the
  file explains *why* those settings exist, so nobody "simplifies" them away.
- `argocd-resource-tracking.md` — two Argo CD defaults that fight this
  single-node stack: label tracking prunes ZITADEL's runtime `login-client`
  secret, and the Ingress health check hangs forever without a LoadBalancer.
  Both fixed by one `argocd-cm` patch at bootstrap.
- `argocd-version-skew.md` — an Argo CD older than the cluster's Kubernetes
  version cannot diff and silently stops reconciling, while still reporting
  `Healthy`. Why the bootstrap runbook no longer pins an old release.

The feedback loop: if an incident's lesson generalizes beyond this
instance, lift the generalizable part into the template
(runbook fix, guardrail, or CI assertion) via PR.
