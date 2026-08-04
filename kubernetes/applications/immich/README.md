# Immich

Immich hosts the wedding photo library and provides password-protected public
share links for guests who do not have an Immich account.

## Endpoints

- Initial/internal setup: `https://immich.rosenvall.local`
- Public endpoint: `https://immich.rosenvall.se`

The public `HTTPRoute` is active. The first administrator was created through
the internal endpoint before it was enabled.

## Runtime layout

- Immich server: `ghcr.io/immich-app/immich-server:v3.1.0`, digest-pinned
- Machine learning: `ghcr.io/immich-app/immich-machine-learning:v3.1.0`,
  digest-pinned, CPU-only
- PostgreSQL 14 with VectorChord: the exact digest used by the Immich v3.1.0
  release compose file
- Valkey 9: the exact digest used by the Immich v3.1.0 release compose file
- Media: the dedicated 2 TiB WD Red-backed NFS export
  `192.168.1.231:/srv/nfs/immich`, mounted directly at `/data`
- Database: 10 GiB `longhorn-critical` PVC with two Longhorn replicas and daily
  local snapshots
- ML model cache and Valkey state: disposable `emptyDir` volumes

The database password is generated once in-cluster by External Secrets and is
never stored in Git or Bitwarden. Deleting the generated `Secret` while keeping
the database PVC will break database access; recover the old password rather
than generating a new one.

## First deployment

1. Push the GitOps changes and wait for the `immich` ArgoCD application to be
   Healthy.
2. Open `https://immich.rosenvall.local` from the LAN and create the initial
   administrator account immediately.
3. Copy the generated `immich-database` password to the password manager. This
   is recovery material for the retained database PVC; never paste it into Git.
4. In Administration > Settings, set the external domain to
   `https://immich.rosenvall.se` and keep the nightly database backup enabled.
5. Verify that `HTTPRoute/immich-public` is `Accepted` before sharing links.

## Sharing wedding photos

Create an album, select Share, and create a public link. Use a password and an
expiry date. Leave guest uploads disabled unless guests should be able to add
their own photos. Do not place Authentik or Cloudflare Access in front of the
route: that would also block unauthenticated Immich share links.

Use the internal hostname for large local imports. Public traffic passes through
Cloudflare Tunnel and is subject to Cloudflare request-size and transfer limits.

## Backup and recovery

Immich writes nightly compressed database backups under `/data/backups`, so they
reside on the same WD Red filesystem as the library. Longhorn snapshots protect
only the live PostgreSQL volume from short-term local failures.

There is currently no automated backup of the WD Red export, and a database
backup on that same filesystem is not an independent copy. Keep the original
wedding photos outside Immich and add a separate backup before treating Immich
as the only library. A complete restore needs both the media directories and a
matching database backup.

Useful checks:

```powershell
$env:KUBECONFIG = (Resolve-Path 'tofu/output/kubeconfig').Path
kubectl get pods,pvc,externalsecret -n immich
kubectl get httproute -n immich
kubectl logs -n immich deployment/immich-server
```

## Upgrade

Read the Immich release and upgrade notes first. Update the server and machine
learning tags and multi-platform digests together. If the release compose file
changes the PostgreSQL image or VectorChord version, follow Immich's database
migration instructions before changing that image.
