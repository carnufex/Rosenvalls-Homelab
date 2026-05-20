# Media

This app groups the local-only media stack that used to run under Docker Compose:

- `radarr`
- `sonarr`
- `jackett`
- `overseerr`
- `plex`
- `deluge-vpn` (`wireguard` + `deluge` in one pod)

## Runtime Contract

- `PersistentVolume/media-library` and `PersistentVolumeClaim/media-library` represent the shared NFS export on `192.168.1.230:/srv/nfs/media`. The active target is VM `media-nfs-01` (`8010`) on `host1`, where `/srv/nfs/media` is mounted from VM `100`'s existing qcow2 media disk on the `lagring` storage.
- Each app keeps its own Longhorn-backed config PVC.
- The namespace is explicitly marked `pod-security.kubernetes.io/enforce=privileged` because Plex uses `hostNetwork` and the WireGuard sidecar needs elevated network privileges.
- Plex scheduling requires a worker labeled `homelab.rosenvall.se/lan-special=true`.
- Radarr, Sonarr, Jackett, Overseerr, and Deluge-VPN prefer workers labeled `homelab.rosenvall.se/proxmox-host=host1`; this keeps non-hostNetwork media workloads close to the NFS VM without making scheduling impossible if `host1` is down.
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
- `Downloads\media\overseerr\config` -> `PersistentVolumeClaim/overseerr-config`
- `Downloads\media\plex\config` -> `PersistentVolumeClaim/plex-config`
- `Downloads\media\deluge\config` -> `PersistentVolumeClaim/deluge-config`

It also removes runtime files and applies known pre-boot config fixes for Jackett and Overseerr. WireGuard configuration is intentionally not copied from the seed payload anymore; update the Bitwarden secret backing `ExternalSecret/deluge-wireguard-config` instead.

## Verification

Verify the shared media PVC before scaling workloads:

```powershell
.\scripts\verify-media-nfs.ps1
```

Verify Deluge VPN after it is live:

```powershell
.\scripts\verify-deluge-vpn.ps1
```

## Access Model

- All browser UIs stay local-only in v1 and are attached directly to `gateway/internal`.
- Included internal hostnames:
  - `https://radarr.rosenvall.local`
  - `https://sonarr.rosenvall.local`
  - `https://jackett.rosenvall.local`
  - `https://overseerr.rosenvall.local`
  - `https://deluge.rosenvall.local`
  - `https://plex.rosenvall.local`
- Plex on the pinned worker's port `32400` remains the primary compatibility path for native clients and discovery traffic.
