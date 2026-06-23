---
name: cloudflare-gateway-routing
description: >-
  Work on or debug public ingress/routing for the Rosenvalls-Homelab cluster:
  Cloudflare Tunnel (cloudflared) → Cilium Gateway API (gateway/external) →
  HTTPRoute → backend service, for hosts under *.rosenvall.se. Use when a public
  site is unreachable, returns Cloudflare 5xx (especially 530), a TLS/cert error,
  or when adding/changing a public HTTPRoute, gateway listener, or wildcard
  certificate.
---

# Cloudflare Gateway Routing

Use this when working on **public** routing in `Rosenvalls-Homelab`. For
internal-only services use `gateway/internal` instead of `gateway/external`.

## Traffic model

```
client → Cloudflare edge → Cloudflare Tunnel → cloudflared (ns: cloudflare)
       → https://cilium-gateway-external.gateway.svc.cluster.local:443
       → Gateway "external" (ns: gateway, HTTPS listener, cert-wildcard)
       → HTTPRoute (host *.rosenvall.se) → backend Service
```

- `cloudflared` runs in-cluster in namespace `cloudflare`.
- The HTTPS listener on `gateway/external` is served by the `cert-wildcard`
  certificate in namespace `gateway`.
- Authentik's HTTPRoute is attached to **both** internal and external gateways so
  OIDC works for public apps; most other monitoring routes should stay internal.

## Diagnostic sequence

Walk it edge-inward and stop at the first failure:

1. **DNS** resolves the host to Cloudflare.
2. **cloudflared** is running and the tunnel is connected.
3. **cert-wildcard** is `Ready`.
4. **gateway/external** has a healthy HTTPS listener (no error conditions).
5. **HTTPRoute** for the host is `Accepted` and bound to `external`.

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"

kubectl get pods -n cloudflare
kubectl logs -n cloudflare deploy/cloudflared --tail=50
kubectl get certificate -n gateway cert-wildcard
kubectl get gateway -n gateway external -o yaml      # inspect .status.listeners conditions
kubectl get httproute -A
kubectl describe httproute <name> -n <namespace>      # look for Accepted / ResolvedRefs
```

## Common failure: Cloudflare 530

A `530` means Cloudflare reached the tunnel but the **origin path inside the
cluster failed**. Check, in this order:

- `cloudflared-secret` / tunnel token missing → cloudflared can't connect
- `cloudflare-api-token-secret` missing → cert-manager DNS-01 can't validate
- `cert-wildcard` not issued → HTTPS listener has no usable cert
- `gateway/external` listener reporting `InvalidCertificateRef`

These are almost always **downstream of a broken External Secrets chain**, which
is in turn usually the Bitwarden bootstrap secret. Before editing routing config,
confirm the secret chain is healthy — see the **cluster-diagnostics** skill and
its note on `bitwarden-access-token`.

## When adding or changing a public route

- Attach the `HTTPRoute` to `parentRefs: name: external, namespace: gateway`.
- Use a `*.rosenvall.se` hostname; the wildcard cert already covers it.
- Add the public `HTTPRoute` **last**, only after the app's image, secrets, and
  health checks are confirmed good (see **gitops-app-onboarding**).
- Push to `origin` — ArgoCD will revert anything applied only with `kubectl`.

## Canonical hostnames

- ArgoCD: `https://argo.rosenvall.se` (legacy alias: `https://argocd.rosenvall.se`)
