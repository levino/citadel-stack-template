# Incident: `ufw` on a k3s node filters nothing

*Not an outage — a **wrong instruction in this runbook**, found by measuring it
instead of trusting it (fresh single-node k3s, Debian 13). It is filed here
because the fix looks like over-engineering next to the one-line `ufw` command
it replaced, and the next agent will otherwise "simplify" it back.*

## What happened

The bootstrap runbook told the operator to open the API port with
`ufw allow 6443/tcp` — implying that `ufw` is a working packet filter on a k3s
node and that everything else was closed. It is not, and they were not. With
`ufw default deny incoming` active and `ufw status` reporting exactly what you
would want to see, **6443 and 10250 answered from the public internet**,
verified from an external host.

## Root cause

k3s installs its own chains and jumps them into `INPUT` **ahead of** ufw's, and
accepts its marked traffic before ufw's chain is ever reached:

```
-P INPUT DROP
-A INPUT ... -j KUBE-ROUTER-INPUT
-A INPUT ... -j KUBE-PROXY-FIREWALL
-A INPUT ... -j KUBE-NODEPORTS
-A INPUT ... -j KUBE-EXTERNAL-SERVICES
-A INPUT -j KUBE-FIREWALL
-A INPUT ... -m mark --mark 0x20000/0x20000 -j ACCEPT   <-- accepted here already
-A INPUT -j ufw-before-input                            <-- ufw only runs here
```

So the ufw policy is real, it is simply never consulted for this traffic. What
k3s exposes on all interfaces on a fresh node:

| Port | Service |
|---|---|
| 6443/tcp | kube-apiserver |
| 10250/tcp | kubelet API |
| 10248, 10249, 10256–10259/tcp | component ports (bound to 127.0.0.1) |
| 8472/udp | flannel VXLAN — **unauthenticated** |

`8472/udp` is the one that matters most. It has no authentication at all:
anyone who can send UDP to it injects packets directly into the pod network,
which bypasses Traefik, ForwardAuth and ZITADEL in one step. The entire
authentication story of this stack sits above a network that is open at the
side door.

Plain `iptables -I INPUT` rules are not a fix either — k3s rewrites its chains
regularly and inserted rules vanish with no warning.

## Symptom / diagnosis

The dangerous property is that there is no symptom. Nothing breaks, nothing
logs, `ufw status` looks correct. The only way to see it is to measure from
outside:

```bash
# from a DIFFERENT machine on the public internet
nc -vz -w3 <server-ip> 6443     # answers, despite ufw deny-by-default
nc -vz -w3 <server-ip> 10250    # answers
iptables -S INPUT | head        # on the node: KUBE-* chains before ufw-before-input
```

## Immediate fix

An own nftables table hooked at a priority *before* the filter table, so it
runs ahead of the k3s chains and survives k3s rewriting its rules. Full recipe,
including persistence and the CI-OIDC exception, in
`runbooks/bootstrap-from-zero.md` §1.2 — do not copy a second version of it
into here.

Shape of it: `type filter hook input priority -150; policy accept`, accept
loopback, established/related, the pod/service CIDRs and the node IP, accept
the `cni0`/`flannel.1` interfaces, then **drop** the k3s TCP ports and
`udp dport 8472`.

Verified after applying it: 22/80/443 open, 6443 and 10250 closed from
outside, `kubectl logs` and `kubectl exec` still working (the apiserver reaches
the kubelet via the permitted node IP), all pods Ready, all Applications
Synced/Healthy.

## Prevention (encoded in this template)

- The bootstrap runbook installs the guard **directly after the k3s install**
  (§1.2), not at the end: between k3s starting and the firewall existing, the
  cluster API is on the internet.
- The `ufw allow 6443` instruction is gone. §7 (CI via GitHub Actions OIDC)
  now punches its hole in the nft guard, and says explicitly that a `ufw allow`
  there would be a no-op that only *looks* like a deliberate exception.
- Do **not** replace the nft table with ufw, and do not "clean up" the
  `policy accept` + drop-list shape into an allow-list — the shape is what
  keeps SSH from locking you out. If ufw is wanted alongside it,
  `DEFAULT_FORWARD_POLICY="ACCEPT"` is required in `/etc/default/ufw` or the
  pod network breaks.
- **Verify from an external host, never from the node.** Two things that look
  like results and are not (both documented in §1.2): an egress proxy makes
  *every* port report open, because the proxy terminates the TCP connection
  locally — scan a port nothing listens on to catch this; and `kubectl exec`
  into a distroless image (ZITADEL) fails for lack of `sh`/`echo`, which reads
  like a broken kubelet path but is only the image — test with busybox.
