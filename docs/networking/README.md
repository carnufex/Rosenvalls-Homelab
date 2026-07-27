# Networking

This cluster uses Cilium Gateway API plus an in-cluster Cloudflare Tunnel.

## Entry Points

- `gateway/external`: public traffic that arrives through Cloudflare Tunnel
- `gateway/internal`: internal-only traffic for services that should not be publicly published

Monitoring routes should stay on the internal gateway unless there is an explicit reason to expose them publicly.

## Internal DNS Contract

Internal browser access uses the local zone `rosenvall.local`.

Create these UDM records:

- `rosenvall.local -> 192.168.1.220`
- `*.rosenvall.local -> 192.168.1.220`
- `media-nfs.rosenvall.local -> 192.168.1.230`

The canonical internal dashboard URL is `https://rosenvall.local`.

`192.168.1.230` is reserved for media NFS and must stay outside the Cilium
LoadBalancer IP pool. The internal and external Gateway services currently use
`192.168.1.220` and `192.168.1.222`.

`https://hub-central.rosenvall.local` is a redirect alias back to the apex dashboard.
`https://headlamp.rosenvall.local` is a redirect alias to the canonical public Headlamp URL, `https://headlamp.rosenvall.se`, so the OIDC callback origin stays consistent.

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

Public `.rosenvall.se` application routes must either use native Authentik/OIDC,
an explicit Authentik proxy exception, or be removed from GitOps until they can
be protected. Current proxy exception is Seerr.

Plex is a special case: `https://plex.rosenvall.se` routes directly to Plex so
native Plex clients, TV apps, and cast targets can reach the server without an
Authentik browser session. Access control for this hostname is Plex's own
authentication and server claim. Local Plex clients can also use the direct LAN
path on `192.168.1.211:32400` or `https://plex.rosenvall.local`. If a TV is on
Guest or IoT, add a narrow firewall allow rule from that source network to
`192.168.1.211:32400`.

## Internal Routing Model

The current internal flow is:

1. LAN DNS resolves `rosenvall.local` and `*.rosenvall.local` to `192.168.1.220`.
2. `gateway/internal` terminates TLS with the cluster-local wildcard certificate.
3. Internal-only `HTTPRoute` objects dispatch traffic to services.

Internal HTTP listeners redirect to HTTPS.

## Internal URLs

- `https://rosenvall.local`
- `https://hub-central.rosenvall.local`
- `https://authentik.rosenvall.local`
- `https://grafana.rosenvall.local`
- `https://headlamp.rosenvall.local` (redirects to `https://headlamp.rosenvall.se`)
- `https://prometheus.rosenvall.local`
- `https://longhorn.rosenvall.local`
- `https://ragflow.rosenvall.local`
- `https://homeassistant.rosenvall.local`
- `https://radarr.rosenvall.local`
- `https://sonarr.rosenvall.local`
- `https://jackett.rosenvall.local`
- `https://seerr.rosenvall.local`
- `https://overseerr.rosenvall.local` (legacy Seerr alias)
- `https://deluge.rosenvall.local`
- `https://plex.rosenvall.local`

## Local CA Export

Export the local CA certificate with:

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
.\scripts\export-local-ca.ps1
```

The default export path is `C:\Users\<user>\Downloads\rosenvall-local-ca.cer`.

## Local CA Trust

### Windows

1. Run `.\scripts\export-local-ca.ps1`
2. Open the exported `.cer` file
3. Choose `Install Certificate`
4. Select `Local Machine`
5. Select `Place all certificates in the following store`
6. Pick `Trusted Root Certification Authorities`
7. Finish the wizard
8. Restart the browser

### macOS

1. Open the exported `.cer` file in Keychain Access
2. Import it into the `System` keychain
3. Open the certificate entry
4. Set `When using this certificate` to `Always Trust`
5. Restart the browser

### iPhone and iPad

1. Copy the `.cer` file to the device
2. Open it and install the profile
3. Go to `Settings -> General -> About -> Certificate Trust Settings`
4. Enable full trust for the imported root certificate

### Android

1. Copy the `.cer` file to the device
2. Install it under `Settings -> Security -> Encryption and credentials -> Install a certificate`
3. Choose `CA certificate`
4. Import it and reopen the browser

### Firefox

Firefox often ignores the OS trust store by default.

Set:

- `about:config`
- `security.enterprise_roots.enabled = true`

## Recovery Checks

Use this order:

```powershell
kubectl get pods -n cloudflare
kubectl get certificate -n gateway cert-wildcard
kubectl get certificate -n gateway cert-local-wildcard
kubectl get gateway -n gateway external -o yaml
kubectl get gateway -n gateway internal -o yaml
kubectl get httproute -A
.\scripts\verify-local-routes.ps1
```

Useful external checks:

```powershell
Resolve-DnsName argo.rosenvall.se
Invoke-WebRequest -Uri https://argo.rosenvall.se -Method Head
```

## Public URLs

- `https://argo.rosenvall.se` and `https://argocd.rosenvall.se` use native Authentik OIDC.
- `https://authentik.rosenvall.se` is the identity provider.
- `https://devops.rosenvall.se` uses native Authentik OIDC.
- `https://headlamp.rosenvall.se` uses native Authentik OIDC.
- `https://seerr.rosenvall.se` uses Authentik through `oauth2-proxy`.
- `https://plex.rosenvall.se` routes directly to Plex for browser, native client, and cast access.
- MatPlan and BikePal are not publicly routed until they have native Authentik/OIDC or an approved proxy exception.

## Implementation Notes

- [Cloudflared component README](../../kubernetes/infrastructure/network/cloudflared/README.md)
- Gateway manifests live under `kubernetes/infrastructure/network/gateway/`
- Argo CD and app-level routes live under their respective manifest directories

## Related Docs

- [Architecture](../architecture/README.md)
- [Operations](../operations/README.md)
- [Disaster recovery](../disaster-recovery/README.md)
