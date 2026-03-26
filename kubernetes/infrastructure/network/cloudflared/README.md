# Cloudflared Setup

This directory contains the in-cluster Cloudflare Tunnel deployment.

## Current model

- The tunnel token lives in Bitwarden.
- External Secrets materializes that token into `cloudflared-secret` in the `cloudflare` namespace.
- The tunnel forwards `*.rosenvall.se` and `rosenvall.se` to `https://cilium-gateway-external.gateway.svc.cluster.local:443`.
- The external Gateway then dispatches traffic to app-level `HTTPRoute` resources.
- The wildcard route must use `matchSNItoHost: true` so Cloudflared presents the requested hostname as SNI to the Gateway. A literal wildcard SNI such as `*.rosenvall.se` breaks TLS routing.

This means the tunnel depends on the full secret chain being healthy:

1. `bitwarden-access-token` must exist in `external-secrets`.
2. `ClusterSecretStore/bitwarden-secretsmanager` must be `Ready`.
3. `ExternalSecret/cloudflared-tunnel-token` must create `cloudflared-secret`.
4. `Deployment/cloudflared` can then start successfully.

## Setup

1. Create the tunnel in Cloudflare Zero Trust.
2. Store the tunnel token in Bitwarden.
3. Put the Bitwarden item UUID in `external-secret.yaml`.
4. Ensure the bootstrap secret `bitwarden-access-token` exists in the cluster.

## Break-glass recovery

If Bitwarden or External Secrets is down and you need the tunnel back temporarily, you can create the runtime secret directly:

```powershell
kubectl create namespace cloudflare --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cloudflare create secret generic cloudflared-secret --from-literal=TUNNEL_TOKEN=<token> --dry-run=client -o yaml | kubectl apply -f -
```

Backfill that state to Bitwarden and External Secrets afterward so GitOps remains the source of truth.
