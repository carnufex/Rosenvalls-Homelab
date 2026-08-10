# Media

This app groups the local-only media stack that used to run under Docker Compose:

- `radarr`
- `sonarr`
- `jackett`
- `seerr`
- `plex`
- `deluge-vpn` (`wireguard` + `deluge` in one pod)

## Runtime Contract

- `PersistentVolume/media-library` and `PersistentVolumeClaim/media-library` represent the shared NFS export on `192.168.1.230:/srv/nfs/media`. The active target is a direct host1 NFS export from `/media/lagring/media`, configured by `scripts/configure-host1-media-nfs.ps1`.
- Do not put the media library qcow2 under OpenTofu or attach it to a VM that can be destroyed by Proxmox automation. VM `media-nfs-01` (`8010`) is retained only as an inactive rollback artifact and must keep `onboot: 0`.
- Proxmox storage `lagring` is host1-only, backup-only, and must keep `is_mountpoint yes`; otherwise other nodes can accidentally expose unrelated local `/media/lagring` directories under the same storage ID or new VM disks can be placed on the external media disk. `scripts/configure-proxmox-lagring-storage-scope.ps1` applies the intended split and keeps desktop's local worker disks on `desktop-lagring`.
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

Rebuild an empty media root after confirmed data loss:

```powershell
.\scripts\configure-host1-media-nfs.ps1 -SourcePath /media/lagring/media -InitializeEmptyMediaRoot
.\scripts\verify-media-nfs.ps1
```

If Radarr and Sonarr must forget the old library, clear only their library records. Do not reset their whole config PVCs; root folders, indexers, API keys, auth, and download clients should be preserved:

```powershell
.\scripts\clear-arr-libraries.ps1
```

This uses the Radarr/Sonarr APIs with `deleteFiles=false`.

If the media disk was lost and Deluge starts against a new empty `/lagring/downloads`, clear Deluge's old queue before starting it. Otherwise Deluge can resume every pre-loss torrent even when Radarr/Sonarr libraries are empty. Back up `/config/state` first, then remove `torrents.state`, `torrents.fastresume`, their `.bak` files, and stale `*.torrent` files.

Seerr also keeps independent request and availability state in `PersistentVolumeClaim/overseerr-config` under `/app/config/db/db.sqlite3`. After a full media-library loss, clear Seerr's media/request/watchlist rows while preserving users and settings:

```powershell
.\scripts\clear-seerr-media-state.ps1
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

If Plex is `Running` but not `Ready` and logs show `Input/output error` under `/config/Library`, treat it as a bad Longhorn config mount before changing Plex settings:

```powershell
kubectl -n media get pod -l app.kubernetes.io/name=plex -o wide
kubectl -n media logs -l app.kubernetes.io/name=plex --tail=120
kubectl -n longhorn-system get volume.longhorn.io pvc-21b281fd-03a2-490e-a02e-1156bb7efe2b -o wide
```

First delete only the Plex pod so Kubernetes remounts `PersistentVolumeClaim/plex-config` cleanly:

```powershell
kubectl -n media delete pod -l app.kubernetes.io/name=plex
kubectl -n media rollout status deploy/plex
```

If the replacement pod still reports filesystem I/O errors, stop Plex and repair or restore `plex-config`. Active R2 Longhorn backups are disabled to avoid Class A operation costs, so prefer a local Longhorn snapshot or the future local MinIO backup path. Historical R2 backups may exist, but verify inventory before relying on them. Do not delete `plex-config` while preserving Plex identity is required.

Plex can also be `Running` while playback fails because the persisted codec cache contains a broken `EasyAudioEncoder` binary. The deployment includes an init container that repairs non-executable `EasyAudioEncoder` binaries at pod startup, and `CronJob/plex-self-heal` checks `/identity` plus the codec cache every five minutes. The CronJob is allowed to delete only the Plex pod in the `media` namespace; it does not delete `plex-config`, media files, libraries, or Longhorn volumes.

Check the semantic Plex health path with:

```powershell
kubectl -n media get pod -l app.kubernetes.io/name=plex -o wide
kubectl -n media exec deploy/plex -- sh -c 'curl -fsS --max-time 10 http://127.0.0.1:32400/identity | grep -q MediaContainer'
kubectl -n media exec deploy/plex -- sh -c 'dir="/config/Library/Application Support/Plex Media Server/Codecs"; [ ! -d "$dir" ] || ! find "$dir" -type f -name EasyAudioEncoder ! -perm -111 | grep -q .'
kubectl -n media get cronjob,job -l app.kubernetes.io/name=plex-self-heal
```

If the codec check fails and you need to repair immediately before GitOps has rolled the init container, delete only the codec cache or the Plex pod. The cache is recreated by Plex; the config PVC is not:

```powershell
kubectl -n media delete pod -l app.kubernetes.io/name=plex
kubectl -n media rollout status deploy/plex
```

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
- Public `https://seerr.rosenvall.se` is an explicit Authentik proxy exception using `oauth2-proxy`.
- Public `https://plex.rosenvall.se` routes directly to Plex so native Plex clients, TV apps, and cast targets can reach the server without an Authentik browser session. Access control for this hostname is Plex's own authentication and server claim.
- Plex on the pinned worker's port `32400` remains the primary LAN compatibility path for native clients and discovery traffic.
- Plex advertises `https://plex.rosenvall.se:443`, `https://plex.rosenvall.local:443`, and `http://192.168.1.211:32400` to native clients.
- If `curl -k -I --resolve plex.rosenvall.se:443:192.168.1.222 https://plex.rosenvall.se/identity` works but normal `https://plex.rosenvall.se/identity` fails, fix the Cloudflare Tunnel public hostname/origin entry rather than restarting Plex.
- Guest/IoT TV clients need an explicit firewall allow rule to reach the direct Plex endpoint `192.168.1.211:32400`. Keep that rule narrow to the TV/Guest/IoT source network and the Plex port.
