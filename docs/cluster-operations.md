# Cluster Operations

## Access

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
```

Base health:

```powershell
kubectl get nodes -o wide
kubectl get applications.argoproj.io -n argocd
kubectl get pods -A
```

## Deterministic Bootstrap Gates

After `bootstrap.ps1`, run the strict gates:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
./scripts/argocd-health-gate.ps1
./scripts/preflight-core.ps1
```

`argocd-health-gate.ps1` validates core apps are `Synced+Healthy`.
`preflight-core.ps1` validates secret chain, cert chain, gateway listener, and route acceptance.

## Bootstrap Secret Recovery

If `ClusterSecretStore/bitwarden-secretsmanager` is not `Ready`, recreate the Bitwarden bootstrap secret first:

```powershell
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic bitwarden-access-token --from-literal=token=<token> --dry-run=client -o yaml | kubectl apply -f -
kubectl get clustersecretstore bitwarden-secretsmanager
kubectl get externalsecret -A
```

Expected downstream secrets after recovery:

- `cloudflared-secret` in `cloudflare`
- `cloudflare-api-token-secret` in `cert-manager`
- `argocd-secret` in `argocd`
- `authentik-core-secrets` and `authentik-blueprint-secrets` in `authentik`
- S3 backup secrets in `authentik`, `cnpg-system`, and `longhorn-system`

## Cloudflare DNS01 Token Contract

The token behind `cert-manager/cloudflare-api-token-secret` must be scoped for the `rosenvall.se` zone and allow:

- Zone read
- DNS edit

If the token does not meet this contract, ACME DNS01 issuance can stall and `gateway/cert-wildcard` will remain non-ready.

## Tunnel And Gateway Recovery

Verify the public routing chain in this order:

```powershell
kubectl get pods -n cloudflare
kubectl get certificate -n gateway cert-wildcard
kubectl get gateway -n gateway external -o yaml
kubectl get httproute -A
```

Useful external checks:

```powershell
Resolve-DnsName argo.rosenvall.se
Invoke-WebRequest -Uri https://argo.rosenvall.se -Method Head
```

## ArgoCD And Authentik

ArgoCD admin password:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
```

Local ArgoCD access:

```powershell
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Authentik is split into:

- `authentik-db-prereqs` (namespace, secrets, CNPG cluster)
- `authentik-runtime` (chart, route, blueprints)
- `authentik-db-ops` (scheduled and manual backups)

Default DB mode is `initdb`. DR restore is opt-in via overlay:

- `kubernetes/infrastructure/controllers/authentik-db-prereqs/overlays/dr-restore`

## Storage Triage

Do not start with Longhorn repairs unless the secret and routing chain is already healthy.

Current storage checks:

```powershell
kubectl get pvc -A
kubectl get volumes.longhorn.io -n longhorn-system
kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana
```

Storage class intent:

- `longhorn` (default): general workloads
- `longhorn-critical`: stateful critical data (for example CNPG)
- `longhorn-observability`: monitoring data (Prometheus/Alertmanager)

Talos node storage intent:

- The VM boot disk backs the Talos `EPHEMERAL` volume, which is where kubelet/containerd image layers, logs, and other transient workload data live.
- The separate worker `longhorn` disk backs only Longhorn replica data under `/var/lib/longhorn`.
- If a node reports `DiskPressure`, inspect the root/ephemeral path even if Longhorn still shows healthy free capacity.

Current provisioning contract:

- New nodes default to `boot_disk_size_gib = 64`.
- Override per-node in `tofu/terraform.tfvars` when needed.
- Existing nodes do not automatically re-provision Talos `EPHEMERAL`; plan a controlled node replacement if you need the larger boot disk to take effect.

If a volume shows filesystem corruption, snapshot/backup first, then execute the documented restore path through GitOps changes.

## GitOps Notes

- ArgoCD syncs the remote GitHub repository, not this local checkout.
- Local `kubectl apply` commands are for verification and break-glass recovery only.
- Any manual recovery that should persist must be reflected back into Git.
