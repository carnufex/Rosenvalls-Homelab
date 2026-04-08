# Networking

This cluster uses Cilium Gateway API plus an in-cluster Cloudflare Tunnel.

## Entry Points

- `gateway/external`: public traffic that arrives through Cloudflare Tunnel
- `gateway/internal`: internal-only traffic for services that should not be publicly published

Monitoring routes should stay on the internal gateway unless there is an explicit reason to expose them publicly.

Internal hostnames use the local DNS zone `*.rosenvall.local`, which should resolve to `192.168.1.220` on the UDM or other LAN DNS.

## Public Routing Model

The current public flow is:

1. Cloudflare receives the hostname.
2. Cloudflare Tunnel forwards to `https://cilium-gateway-external.gateway.svc.cluster.local:443`.
3. The external gateway terminates TLS with the wildcard certificate.
4. `HTTPRoute` objects dispatch traffic to services.

This means the public path depends on all of the following:

- the manual Bitwarden bootstrap token
- `ClusterSecretStore/bitwarden-secretsmanager`
- the Cloudflare tunnel token `ExternalSecret`
- the wildcard certificate
- the external gateway listener
- accepted `HTTPRoute` resources

## Current Manual Contract

The tunnel runtime is Git-managed, but the published application routes are still managed in the Cloudflare dashboard.

For wildcard routing to work, the published route for `*.rosenvall.se` must enable `Match SNI to Host`.

## Internal Routing Model

The current internal flow is:

1. LAN DNS resolves `*.rosenvall.local` to `192.168.1.220`.
2. `gateway/internal` terminates TLS with a cluster-local wildcard certificate for `*.rosenvall.local`.
3. Internal-only `HTTPRoute` objects dispatch traffic to services.

To avoid browser warnings, LAN clients must trust the local CA certificate stored in the `gateway-local-ca` secret in the `gateway` namespace.

## URLs

- ArgoCD canonical URL: `https://argo.rosenvall.se`
- ArgoCD legacy alias: `https://argocd.rosenvall.se`

Authentik is attached to both internal and external gateways so OIDC can work for public apps.

## Internal URLs

- `https://authentik.rosenvall.local`
- `https://grafana.rosenvall.local`
- `https://prometheus.rosenvall.local`
- `https://longhorn.rosenvall.local`
- `https://ragflow.rosenvall.local`
- `https://hub-central.rosenvall.local`
- `https://homeassistant.rosenvall.local`
- `https://radarr.rosenvall.local`
- `https://sonarr.rosenvall.local`
- `https://jackett.rosenvall.local`
- `https://overseerr.rosenvall.local`
- `https://deluge.rosenvall.local`
- `https://plex.rosenvall.local`

Export the local CA certificate for client trust distribution:

```powershell
kubectl -n gateway get secret gateway-local-ca -o jsonpath="{.data.tls\.crt}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
```

## Recovery Checks

Use this order:

```powershell
kubectl get pods -n cloudflare
kubectl get certificate -n gateway cert-wildcard
kubectl get certificate -n gateway cert-local-wildcard
kubectl get gateway -n gateway external -o yaml
kubectl get gateway -n gateway internal -o yaml
kubectl get httproute -A
```

Useful external checks:

```powershell
Resolve-DnsName argo.rosenvall.se
Invoke-WebRequest -Uri https://argo.rosenvall.se -Method Head
```

## Implementation Notes

- [Cloudflared component README](../../kubernetes/infrastructure/network/cloudflared/README.md)
- Gateway manifests live under `kubernetes/infrastructure/network/gateway/`
- ArgoCD and app-level routes live under their respective manifest directories

## Related Docs

- [Architecture](../architecture/README.md)
- [Operations](../operations/README.md)
- [Disaster recovery](../disaster-recovery/README.md)
