# Media

This app groups the local-only media stack that used to run under Docker Compose:

- `radarr`
- `sonarr`
- `jackett`
- `overseerr`
- `plex`
- `deluge-vpn` (`wireguard` + `deluge` in one pod)

## Runtime Contract

- `PersistentVolume/media-library` and `PersistentVolumeClaim/media-library` represent the shared NFS export from the USB disk. Update the NFS server IP and export path if your final export differs from the placeholder values in `media-library-pv.yaml`.
- Each app keeps its own Longhorn-backed config PVC. Existing app config directories should be copied into those PVCs before traffic is switched.
- The namespace is explicitly marked `pod-security.kubernetes.io/enforce=privileged` because Plex uses `hostNetwork` and the WireGuard sidecar needs elevated network privileges.
- Plex scheduling requires a worker labeled `homelab.rosenvall.se/lan-special=true`. The included Tofu changes add that label to the example `worker-01` definition.
- Internal browser access is handled with `HTTPRoute` resources on `gateway/internal`, so LAN clients should resolve `*.rosenvall.local` to `192.168.1.220` on the UDM.
- Internal HTTPS for `*.rosenvall.local` uses the cluster-local CA managed in the `gateway` namespace.
- All media deployments start at `replicas: 0` in Git so you can seed config, confirm NFS reachability, and update the Deluge VPN endpoint policy before the workloads are brought live.

## Deluge VPN Model

- `wireguard` and `deluge` share one pod and therefore one network namespace.
- `wireguard` is expected to own the pod's default route.
- `deluge` is only considered healthy when `/config/wg0.conf` exists and the default route points to `wg0`.
- `CiliumNetworkPolicy/deluge-vpn-egress-lockdown` intentionally denies normal egress unless the DNS and VPN endpoint rules are updated to match the real `wg0.conf`.

## Manual Seeding

Copy the existing Docker directories into the matching PVC-backed config paths:

- `./radarr/config` -> `PersistentVolumeClaim/radarr-config`
- `./sonarr/config` -> `PersistentVolumeClaim/sonarr-config`
- `./jackett/config` -> `PersistentVolumeClaim/jackett-config`
- `./overseerr/config` -> `PersistentVolumeClaim/overseerr-config`
- `./plex/config` -> `PersistentVolumeClaim/plex-config`
- `./deluge/config` plus `./wireguard/wg0.conf` -> `PersistentVolumeClaim/deluge-config`

Also export the USB disk over NFS before syncing this app and confirm that the export contains the expected subdirectories:

- `/tv`
- `/movies`
- `/familjefilmer`

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
- If you add a wildcard `*.rosenvall.local -> 192.168.1.220` on the UDM, every LAN hostname you expect to work must also have a matching `HTTPRoute` on `gateway/internal`.
