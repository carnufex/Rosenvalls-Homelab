# Cloudflared Setup

This directory contains the in-cluster Cloudflare Tunnel deployment.

## Current model

- The tunnel token lives in Bitwarden.
- External Secrets materializes that token into `cloudflared-secret` in the `cloudflare` namespace.
- The running tunnel is token-managed (`cloudflared tunnel run --token ...`), so published application routes and origin parameters are currently sourced from the Cloudflare dashboard, not from this repository.
- The tunnel forwards `*.rosenvall.se` and `rosenvall.se` to `https://cilium-gateway-external.gateway.svc.cluster.local:443`.
- The external Gateway then dispatches traffic to app-level `HTTPRoute` resources.
- The wildcard published route in Cloudflare must enable `Match SNI to Host` so Cloudflared presents the requested hostname as SNI to the Gateway. A literal wildcard SNI such as `*.rosenvall.se` breaks TLS routing and returns Cloudflare `502`.
- If a public hostname returns Cloudflare `503 no healthy upstream` while the same hostname works with `curl --resolve <host>:443:192.168.1.222`, the in-cluster Gateway and `HTTPRoute` are healthy and the Cloudflare dashboard route for that hostname is misconfigured or pointing at the wrong origin.
- The local tunnel config is still generated through `configMapGenerator`, so process-level config changes roll the `cloudflared` pods automatically via the hashed ConfigMap name.

This means the tunnel depends on the full secret chain being healthy:

1. `bitwarden-access-token` must exist in `external-secrets`.
2. `ClusterSecretStore/bitwarden-secretsmanager` must be `Ready`.
3. `ExternalSecret/cloudflared-tunnel-token` must create `cloudflared-secret`.
4. `Deployment/cloudflared` can then start successfully.

## Setup

1. Create the tunnel in Cloudflare Zero Trust.
2. Store the tunnel token in Bitwarden.
3. In Cloudflare Zero Trust, define the published application routes that point at the external Gateway.
4. For the wildcard route `*.rosenvall.se`, enable `Match SNI to Host` in Additional application settings.
5. Put the Bitwarden item UUID in `external-secret.yaml`.
6. Ensure the bootstrap secret `bitwarden-access-token` exists in the cluster.

## Public route triage

Use the gateway-direct comparison before changing Kubernetes manifests:

```powershell
curl.exe -k -I https://headlamp.rosenvall.se
curl.exe -k -I --resolve headlamp.rosenvall.se:443:192.168.1.222 https://headlamp.rosenvall.se
```

For app hostnames such as `headlamp.rosenvall.se` and `plex.rosenvall.se`, the Cloudflare route should use:

- origin service: `https://cilium-gateway-external.gateway.svc.cluster.local:443`
- `No TLS Verify`: enabled
- `Match SNI to Host`: enabled
- HTTP Host Header override: unset

If gateway-direct returns the expected app response but Cloudflare returns `503`, fix the Cloudflare Tunnel public hostname/origin entry. Restarting app pods or changing `HTTPRoute` resources will not fix that class of failure.

Current known failure pattern: `headlamp.rosenvall.se`, `plex.rosenvall.se`, and
`seerr.rosenvall.se` can return Cloudflare `503 no healthy upstream` while
gateway-direct returns `200` or Authentik `302`. In that case:

1. Check that no more-specific published application route for the hostname exists in another tunnel or app.
2. Keep the wildcard `*.rosenvall.se` route pointed at the external Cilium Gateway.
3. If wildcard routing still fails for only those hostnames, create explicit published application routes for those hostnames with the same origin settings as the wildcard route.

## Break-glass recovery

If Bitwarden or External Secrets is down and you need the tunnel back temporarily, you can create the runtime secret directly:

```powershell
kubectl create namespace cloudflare --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cloudflare create secret generic cloudflared-secret --from-literal=TUNNEL_TOKEN=<token> --dry-run=client -o yaml | kubectl apply -f -
```

Backfill that state to Bitwarden and External Secrets afterward so GitOps remains the source of truth.
