# Scaling

This page covers node lifecycle work: add, remove, and rebuild.

## Current Posture

- Adding or replacing worker nodes is reasonably declarative through `nodes_config`.
- Removing or rebuilding a worker still requires an operator runbook and health gates.
- Adding more control plane nodes is supported by the configuration model, but it is not yet a low-risk, routinely validated path in this repo.
- GPU nodes are not fully declarative because Proxmox passthrough still requires manual GUI work.
- The checked-in example topology is smaller than the failure-domain assumptions baked into the 2-replica Longhorn profiles.

## Naming Conventions

- Prefer `<control-plane-node>` and `<worker-node>` in generic procedures.
- Use `control-01` and `worker-01` as concrete examples.

## Add A Worker

1. Add a new worker entry to `nodes_config` in local `terraform.tfvars`.
2. Keep node-specific disk sizing explicit if you do not want existing nodes to inherit a new default.
3. Run `tofu plan`.
4. Review the plan carefully for accidental replacements.
5. Run `tofu apply`.
6. Verify the new worker becomes `Ready`.
7. Run:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
.\scripts\argocd-health-gate.ps1
.\scripts\preflight-core.ps1
```

For the current two-Proxmox-host topology, `worker-04` on `host1`
(`192.168.1.214`) is the first expansion worker. It adds useful capacity and a
second physical failure domain without changing etcd quorum.

When adding workers on a Proxmox host that is not the default image node, the
Talos module downloads the Talos image to that node's local ISO storage as well.
This is required because Proxmox `local` storage is node-local.

## Add A Control Plane Node

The repo can model more control plane nodes, but this should be treated as an advanced change until it is proven and documented in a dedicated HA runbook.

Do not add a second control plane and call the cluster HA. Kubernetes/etcd
control-plane HA normally needs three control-plane members for quorum. With two
physical Proxmox hosts, a three-member control plane still has an unavoidable
2/1 placement tradeoff.

Use this posture today:

- add the node declaratively in `nodes_config`
- review `tofu plan` for any unintended replacement of the existing control plane
- treat the change as higher risk than a worker add
- verify Talos membership and Kubernetes control plane health before making any more changes

## Rolling Worker Rebuild

Use this when a worker needs a larger Talos boot disk or a clean reprovision.

1. If needed, add a temporary worker first so the cluster keeps enough healthy workers.
2. Run the worker maintenance gate:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
.\scripts\preflight-worker-rebuild.ps1 -TargetNode worker-01
```

3. Cordon and drain the target worker:

```powershell
kubectl cordon worker-01
kubectl drain worker-01 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=15m
```

4. Reset the old Talos node and remove it from Kubernetes:

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
talosctl reset --nodes 192.168.1.211 --endpoints 192.168.1.201 --graceful=false --reboot=false
kubectl delete node worker-01
```

5. Recreate it through OpenTofu with an explicit replace:

```powershell
cd tofu
tofu plan -replace='module.talos.proxmox_virtual_environment_vm.this["worker-01"]'
tofu apply -replace='module.talos.proxmox_virtual_environment_vm.this["worker-01"]'
cd ..
```

6. Re-run the core gates after the node returns.

## Remove A Worker Safely

1. Confirm the cluster has enough healthy workers for the target workload set.
2. Run `.\scripts\preflight-worker-rebuild.ps1` first.
3. Cordon and drain the node.
4. Reset the Talos node so it leaves cleanly.
5. Delete the Kubernetes node object if needed.
6. Remove the worker from local `terraform.tfvars`.
7. Run `tofu plan` and `tofu apply`.
8. Re-run the core gates.

## What Is Easy Today

- adding a normal worker
- replacing a worker with a documented maintenance flow
- validating cluster health after a node change

## What Is Still Manual Or Higher Risk

- control plane expansion
- GPU node changes
- safe reuse of local access artifacts from a different workstation
- any workflow that depends on undocumented external state

## Related Docs

- [Operations](../operations/README.md)
- [Disaster recovery](../disaster-recovery/README.md)
- [Storage and backups](../storage-and-backups/README.md)
