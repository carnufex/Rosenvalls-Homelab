# Media

This app groups the local-only media stack that used to run under Docker Compose:

- `radarr`
- `sonarr`
- `jackett`
- `seerr`
- `plex`
- `deluge-vpn` (`wireguard` + `deluge` in one pod)

## Runtime Contract

- `PersistentVolume/media-library` and `PersistentVolumeClaim/media-library` represent the shared NFS export on `192.168.1.230:/srv/nfs/media`. The active target is VM `media-nfs-01` (`8010`) on `host1`, where `/srv/nfs/media` is mounted from VM `100`'s existing qcow2 media disk on the `lagring` storage.
- Each app keeps its own Longhorn-backed config PVC.
- The namespace is explicitly marked `pod-security.kubernetes.io/enforce=privileged` because Plex uses `hostNetwork` and the WireGuard sidecar needs elevated network privileges.
- Plex scheduling requires a worker labeled `homelab.rosenvall.se/lan-special=true`.
- Radarr, Sonarr, Jackett, Seerr, and Deluge-VPN prefer workers labeled `homelab.rosenvall.se/proxmox-host=host1`; this keeps non-hostNetwork media workloads close to the NFS VM without making scheduling impossible if `host1` is down.
- Internal browser access is handled with `HTTPRoute` resources on `gateway/internal`, so LAN clients should resolve `*.rosenvall.local` to `192.168.1.220` on the UDM.
- Media configs are seeded from `Downloads\media` before cutover, but the deployments are now managed directly in Git and scaled individually as each app is validated.

## Deluge VPN Model

- `wireguard` and `deluge` share one pod and therefore one network namespace.
- `wg0.conf` is sourced from Bitwarden Secrets Manager through `ExternalSecret/deluge-wireguard-config`, then mounted read-only as `/config/wg_confs/wg0.conf`.
- `wireguard` is expected to install policy routing for table `51820`, with `default dev wg0` in that table and explicit route exceptions for cluster/LAN networks.
- `deluge-vpn` is only considered healthy when `/config/wg_confs/wg0.conf` exists, `wg0` is up, and WireGuard policy routing is present.
- `CiliumNetworkPolicy/deluge-vpn-egress-lockdown` only allows DNS plus the configured WireGuard endpoint `wireguard.5july.net:48575`.

## Seeding

Seed the media app PVCs with:

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
.\scripts\seed-media-configs.ps1
```

The seed script copies:

- `Downloads\media\jackett\config` -> `PersistentVolumeClaim/jackett-config`
- `Downloads\media\radarr\config` -> `PersistentVolumeClaim/radarr-config`
- `Downloads\media\sonarr\config` -> `PersistentVolumeClaim/sonarr-config`
- `Downloads\media\overseerr\config` -> `PersistentVolumeClaim/overseerr-config` for Seerr migration
- `Downloads\media\plex\config` -> `PersistentVolumeClaim/plex-config`
- `Downloads\media\deluge\config` -> `PersistentVolumeClaim/deluge-config`

It also removes runtime files and applies known pre-boot config fixes for Jackett and Seerr. WireGuard configuration is intentionally not copied from the seed payload anymore; update the Bitwarden secret backing `ExternalSecret/deluge-wireguard-config` instead.

After Radarr and Sonarr are running from restored config, rewrite old Docker endpoints to in-cluster services:

```powershell
.\scripts\update-media-internal-endpoints.ps1 -Test
```

This keeps existing API keys and passwords, but changes Deluge clients to `deluge.media.svc.cluster.local:8112` and Jackett Torznab URLs to `jackett.media.svc.cluster.local:9117`.

## Verification

Verify the shared media PVC before scaling workloads:

```powershell
.\scripts\verify-media-nfs.ps1
```

If Radarr, Sonarr, or Seerr remain in `ContainerCreating` after a node restart, check the config PVCs before changing app manifests:

```powershell
kubectl -n media get pods,pvc
kubectl -n media describe pod -l app.kubernetes.io/name=radarr
kubectl -n media describe pod -l app.kubernetes.io/name=sonarr
kubectl -n media describe pod -l app.kubernetes.io/name=seerr
kubectl -n longhorn-system get orphan -o wide
kubectl -n longhorn-system get volume.longhorn.io
```

Longhorn `engine-instance` orphans that match the stuck config PVC can block attach after a node restart. Delete only matching orphan resources, then delete the stuck media pod so Kubernetes creates a clean replacement. Do not delete media PVCs or Longhorn replicas unless a backup/restore path has been explicitly chosen.

Verify Deluge VPN after it is live:

```powershell
.\scripts\verify-deluge-vpn.ps1
```

This verifies the WireGuard interface, policy routing, external IP through the tunnel, the Cilium egress policy, and that a forced direct `eth0` request cannot bypass the tunnel. A stronger destructive fail-closed test is to bring `wg0` down temporarily and confirm the pod becomes unready and cannot reach the internet, but only do that during a maintenance window because it interrupts active torrents.

## Access Model

- Media browser UIs are internal by default and attached directly to `gateway/internal`.
- Included internal hostnames:
  - `https://radarr.rosenvall.local`
  - `https://sonarr.rosenvall.local`
  - `https://jackett.rosenvall.local`
  - `https://seerr.rosenvall.local`
  - `https://overseerr.rosenvall.local` (legacy alias)
  - `https://deluge.rosenvall.local`
  - `https://plex.rosenvall.local`
- Public `https://seerr.rosenvall.se` and `https://plex.rosenvall.se` are explicit Authentik proxy exceptions using `oauth2-proxy`.
- Plex on the pinned worker's port `32400` remains the primary compatibility path for native clients and discovery traffic.
- Public Plex browser traffic goes through Authentik first, then `plex-oauth2-proxy` forwards to `plex.media.svc.cluster.local:32400`.
