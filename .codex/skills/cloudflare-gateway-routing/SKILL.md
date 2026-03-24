# Cloudflare Gateway Routing

Use this guide when working on public routing in `Rosenvalls-Homelab`.

## Current Model

- `cloudflared` runs in-cluster.
- Tunnel traffic for `*.rosenvall.se` is forwarded to `https://cilium-gateway-external.gateway.svc.cluster.local:443`.
- Gateway API listeners then route traffic to backend services through `HTTPRoute`.

## Diagnostic Sequence

1. Confirm DNS resolves.
2. Confirm `cloudflared` is running.
3. Confirm `cert-wildcard` is `Ready`.
4. Confirm `gateway/external` has a healthy HTTPS listener.
5. Confirm the target `HTTPRoute` is `Accepted`.

## Common Failure Pattern

If external requests return Cloudflare `530`, first check:

- missing `cloudflared-secret`
- missing `cloudflare-api-token-secret`
- `cert-wildcard` not issued
- `Gateway` listener reporting `InvalidCertificateRef`

These are usually caused upstream by a broken External Secrets chain.
