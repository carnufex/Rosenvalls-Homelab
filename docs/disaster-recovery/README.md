# Disaster Recovery

This page documents the current recovery posture as it actually exists today.

## Recovery Modes

### Cold Rebuild

Use this when the server is replaced, lost, or stolen and you are willing to rebuild the cluster from code.

What Git gives you:

- Proxmox VM definitions
- Talos machine configuration generation
- GitOps manifests
- bootstrap procedure
- documented Authentik restore overlay

What Git does not give you:

- Proxmox credentials
- `bitwarden-access-token`
- Cloudflare dashboard-side tunnel publishing
- local `terraform.tfvars`
- an off-machine copy of `tofu/output/kubeconfig`
- an off-machine copy of `tofu/output/talosconfig`

### State-Preserving Recovery

Use this when you need more than a fresh rebuild, for example preserving existing access paths, identities, or database history with the least disruption.

This is only partially documented today. Authentik has a restore story. Several other stateful workloads do not.

## New Server Or Stolen Server Runbook

1. Prepare the replacement server and restore Proxmox access.
2. Restore or recreate local `tofu/terraform.tfvars`.
3. Run `tofu init`, `tofu plan`, and `tofu apply`.
4. Export `TALOSCONFIG` and `KUBECONFIG` from `tofu/output/`.
5. Verify Talos and Kubernetes API health.
6. Restore the manual `bitwarden-access-token` path or pass it into `bootstrap.ps1`.
7. Run `bootstrap.ps1`.
8. Run `.\scripts\argocd-health-gate.ps1` and `.\scripts\preflight-core.ps1`.
9. Restore application state only where backup and restore paths are documented.
10. Rotate secrets and external credentials if the old server was stolen or otherwise untrusted.

## Restore Matrix

| Area | Current posture | Notes |
| --- | --- | --- |
| Core cluster bootstrap | Strong | OpenTofu + Talos + `bootstrap.ps1` are codified |
| Secret chain bootstrap | Manual dependency | Requires `bitwarden-access-token` |
| Public routing | Partial | In-cluster connector is in Git, published routes are dashboard-managed |
| Authentik database | Documented restore path | Restore overlay and S3 backup contract exist |
| Longhorn volumes | Partial | Backup target exists, recurring offsite backup policy is not codified here |
| MatPlan data | Weak | Runtime is defined, restore path is not documented |
| Talos/Kubernetes access artifacts | Weak | Generated locally, no repo-defined off-machine backup policy |

## Bootstrap Secret Recovery

If `ClusterSecretStore/bitwarden-secretsmanager` is not `Ready`, recreate the bootstrap secret first:

```powershell
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic bitwarden-access-token --from-literal=token=<token> --dry-run=client -o yaml | kubectl apply -f -
kubectl get clustersecretstore bitwarden-secretsmanager
kubectl get externalsecret -A
```

This should restore downstream secret materialization for Cloudflare, cert-manager, ArgoCD, Authentik, and backup credentials.

## Routing Recovery

Validate this chain in order:

```powershell
kubectl get pods -n cloudflare
kubectl get certificate -n gateway
kubectl get gateway -n gateway external -o yaml
kubectl get httproute -A
```

If the wildcard route still fails while the cluster objects are healthy, inspect the Cloudflare dashboard-side published route and confirm `Match SNI to Host` is enabled.

## Authentik Restore

Authentik is the best-documented restore path in the repo today.

- default mode: `initdb`
- restore mode: switch to the `dr-restore` overlay under `authentik-db-prereqs`
- live backups: `s3://rosenvall-homelab-backup/authentik/live/`
- DR overlay writes to: `s3://rosenvall-homelab-backup/authentik/dr/`

Do not mix backup prefixes between fresh bootstrap and DR-restored clusters.

## What Must Exist Outside Git

- Proxmox credentials
- Bitwarden access token
- Cloudflare tunnel and published route ownership
- Cloudflare DNS API token contract
- R2 credentials
- local `terraform.tfvars`
- a secure backup policy for `tofu/output/kubeconfig` and `tofu/output/talosconfig`

## Priority Backlog

- `P0`: write a fully validated new-server and stolen-server runbook from bare metal to green core gate
- `P1`: verify restore stories for each stateful system and document where restore is only theoretical
- `P2`: codify Longhorn backup policy, add a MatPlan restore story, reduce dashboard-only dependencies, and evaluate a more HA control plane

## Related Docs

- [Getting started](../getting-started/README.md)
- [Operations](../operations/README.md)
- [Networking](../networking/README.md)
- [Storage and backups](../storage-and-backups/README.md)
