# Wedding-POV (wedding photo/video upload)

Onboarding of the Wedding-POV app (source repo `C:\Users\Crille\source\repos\Wedding-POV`)
into the cluster. Adapts the app's `deploy/` to homelab conventions: kustomize
under `kubernetes/applications/`, Cilium Gateway `HTTPRoute` instead of Ingress,
and Bitwarden `ExternalSecret`s instead of inline secrets.

## Components

| Component | Image | Storage | Status |
|---|---|---|---|
| **postgres** (metadata) | `postgres:17-alpine` | Longhorn 5Gi (RWO) | ✅ deployed |
| **minio** (S3 blobs) | `minio/minio` | **NFS** 192.168.1.230 `/srv/nfs/media/wedding-minio` | ✅ deployed |
| **postgres-backup** | `postgres:17-alpine` | Longhorn 5Gi | ✅ daily pg_dump 03:00 |
| **web** (Next.js) | `ghcr.io/carnufex/wedding-pov` | stateless | ⏳ needs GHCR image |

## Storage decision

MinIO data is on the **existing NFS server** (same as media-library), NOT the WD
Red disk. WD-red is a 4 TB LVM pool on the `desktop` Proxmox node; using it as
k8s storage needs a Talos `disks` machine-config (like worker-04), and `tofu
apply` is currently blocked by the Talos image drift. Revisit WD-red after that
drift is resolved if dedicated storage is wanted. The MinIO PV points at a
`wedding-minio` subdir of the media NFS export — **create it once** (the subdir
must exist before the PV mounts):

```bash
# one-off: mkdir the subdir on the NFS server via a pod that mounts the export
kubectl -n media run nfs-mkdir --rm -it --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"m","image":"busybox","command":["sh","-c","mkdir -p /m/wedding-minio && ls -ld /m/wedding-minio"],"volumeMounts":[{"name":"m","mountPath":"/m"}]}],"volumes":[{"name":"m","persistentVolumeClaim":{"claimName":"media-library"}}]}}'
```

## Secrets (Bitwarden, homelab project)

Generated, not the app's CHANGE-ME placeholders. Pulled via ExternalSecret into
`postgres-secret`, `minio-secret`, `web-secret`:

- `wedding-pg-password` · `wedding-minio-user` · `wedding-minio-password`
- `wedding-admin-password` · `wedding-session-secret`

## Hostnames (flat — covered by the `*.rosenvall.se` wildcard cert)

- Web: `bröllop.rosenvall.se` (punycode `xn--brllop-xxa.rosenvall.se`) — single
  label, so the `*.rosenvall.se` wildcard cert covers it; browsers display the ö.
- MinIO public (presigned uploads): `brollop-media.rosenvall.se` (flat, behind
  the scenes — guests never see it).

(The app's original `media.bröllop.rosenvall.se` is two labels deep and would not
be covered by the wildcard, so the media endpoint stays a flat single label.)

**DNS:** `xn--brllop-xxa.rosenvall.se` must resolve to the Cloudflare tunnel
(covered if `*.rosenvall.se` is a wildcard record; otherwise add the record).

## To finish onboarding (after the image exists)

1. In the Wedding-POV repo: build + push `ghcr.io/carnufex/wedding-pov` (set the
   ref in this repo's `web.yaml`, already done) and add a GitHub Actions workflow.
2. Add `ghcr-image-pull-secret.yaml` (copy the gatebound/matplan ExternalSecret).
3. Uncomment `ghcr-image-pull-secret.yaml`, `web.yaml`, `httproute.yaml` in
   `kustomization.yaml`, push.
4. Verify web health, then the public routes serve guests.
