# Migrations And Cutover

This page is the runbook for the Docker-to-Kubernetes app migration.

## Current Target Model

- Internal portal: `https://rosenvall.local`
- Internal wildcard zone: `*.rosenvall.local`
- Internal gateway IP: `192.168.1.220`
- Media NFS helper VM: `media-nfs-01` on `192.168.1.230`
- Media export path: `/srv/nfs/media`
- Legacy Docker host kept for rollback: `192.168.1.112`

## UDM DNS Records

Create these A records on the UDM:

- `rosenvall.local -> 192.168.1.220`
- `*.rosenvall.local -> 192.168.1.220`
- `media-nfs.rosenvall.local -> 192.168.1.230`

Keep legacy `*.server.home` records only during the migration window.

## NFS Provisioning

`tofu/media-nfs.tf` provisions a small Debian 12 helper VM on the Proxmox node `desktop`.

Expected shape:

- VM name: `media-nfs-01`
- IP: `192.168.1.230`
- boot disk: `32Gi` on `local-lvm`
- data disk: `4.5T` on `WD-red`
- export path: `/srv/nfs/media`
- exported directories:
  - `downloads`
  - `tv`
  - `movies`
  - `familjefilmer`

The cloud-init bootstrap formats the data disk if needed, mounts it, creates the media directories, and exports the share only to worker nodes `192.168.1.211`, `192.168.1.212`, and `192.168.1.213`.

## Seed Commands

Export kubeconfig first:

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
```

Seed Home Assistant:

```powershell
.\scripts\seed-homeassistant.ps1
```

Seed media app configs:

```powershell
.\scripts\seed-media-configs.ps1
```

What the seed scripts do:

- create a temporary helper pod that mounts the target PVC
- copy the staged config into the PVC
- remove runtime files such as `*.pid`, `deluged.pid`, and `.ha_run.lock`
- patch known config drift before first boot

Current automatic seed adjustments:

- Home Assistant:
  - forces `use_x_forwarded_for: true`
  - sets `trusted_proxies` to `10.0.0.0/8` and `127.0.0.1`
  - sets `.storage/core.config` internal and external URL to `https://homeassistant.rosenvall.local`
- Jackett:
  - changes `LocalBindAddress` to `0.0.0.0`
- Overseerr:
  - enables proxy trust
  - sets `applicationUrl` to `https://overseerr.rosenvall.local`
  - rewrites Radarr, Sonarr, and Plex hosts to in-cluster service DNS
- Deluge:
  - copies `wireguard/wg0.conf` into the same PVC as `/config/wg0.conf`

## Verification Commands

Routes:

```powershell
.\scripts\verify-local-routes.ps1
```

Media NFS:

```powershell
.\scripts\verify-media-nfs.ps1
```

Deluge VPN:

```powershell
.\scripts\verify-deluge-vpn.ps1
```

Local CA export:

```powershell
.\scripts\export-local-ca.ps1
```

## Cutover Order

Bring workloads live in this order:

1. `jackett`
2. `radarr`
3. `sonarr`
4. `plex`
5. `overseerr`
6. `homeassistant`
7. `deluge-vpn`

After each app is live:

1. Verify the route on `https://<app>.rosenvall.local`
2. Verify `http://<app>.rosenvall.local` redirects to HTTPS
3. Verify the expected storage path is mounted
4. Verify the app can reach its dependencies
5. Stop the old Docker container only after the Kubernetes app passes smoke tests

## App Checklists

### Jackett

- Seed PVC
- Scale deployment to `1`
- Verify `https://jackett.rosenvall.local`
- Verify Torznab endpoints respond
- Keep the old Docker container until Radarr and Sonarr are pointed at the new instance

### Radarr

- Seed PVC
- Scale deployment to `1`
- Verify `/lagring/movies`
- Verify `/lagring/downloads`
- Verify indexers point to Jackett in-cluster
- Keep download client on the old Docker Deluge until the Deluge cutover

### Sonarr

- Seed PVC
- Scale deployment to `1`
- Verify `/lagring/tv`
- Verify `/lagring/downloads`
- Verify indexers point to Jackett in-cluster
- Keep download client on the old Docker Deluge until the Deluge cutover

### Plex

- Seed PVC
- Scale deployment to `1` on the labeled `lan-special` worker
- Verify the libraries `tv`, `movies`, and `familjefilmer`
- Verify direct client compatibility on port `32400`

### Overseerr

- Seed PVC
- Scale deployment to `1`
- Verify it can reach Radarr, Sonarr, and Plex
- Verify a test request flows through

### Home Assistant

- Seed PVC
- Scale deployment to `1`
- Verify `https://homeassistant.rosenvall.local`
- Verify no reverse-proxy warning is shown
- Verify at least one important integration or automation

### Deluge VPN

- Seed PVC and `wg0.conf`
- Scale deployment to `1`
- Verify `wg0` exists and default route is through the tunnel
- Verify the external IP is the VPN IP
- Repoint Radarr and Sonarr to `deluge.media.svc.cluster.local`

## Rollback

If a migrated app regresses:

1. scale the Kubernetes deployment back to `0`
2. leave the PVC intact
3. start the old Docker container again
4. revert only the dependency rewrites for downstream apps
5. keep the NFS share and route manifests in place unless they are the direct cause

Keep the old Docker Compose stack powered off but intact for at least seven days after the final cutover.
