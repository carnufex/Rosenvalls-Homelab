# Authentik DB Prereqs

This app contains the Authentik namespace, runtime secrets, and CloudNativePG cluster.

## Current Stability Posture

The live cluster currently runs Authentik PostgreSQL as a single-instance cluster with
`20Gi` of WAL storage to prioritize service recovery over database HA. Restore a second
instance only after the primary is healthy and WAL growth is confirmed stable.

## Default Mode

The default manifest uses `initdb` for deterministic new cluster bootstrap.
The Homelab Bitwarden Secrets Manager project must contain these separate
secrets so Authentik pre-creates the `akadmin` account during first startup
instead of leaving the public first-run setup flow claimable:

- `authentik-bootstrap-password`
- `authentik-bootstrap-token`
- `authentik-bootstrap-email`

Do not sync this change to the live cluster until those Bitwarden secrets exist.
If any secret is missing, External Secrets cannot render
`Secret/authentik-core-secrets`.

The manifest references the Bitwarden Secrets Manager secret IDs directly after
the bootstrap secrets have been created.

## Backup And DR Status

Active Authentik CNPG backups to Cloudflare R2 are disabled to avoid R2 Class A operation costs. The live cluster currently relies on Longhorn replicas and local snapshots for immediate recovery. A new local S3-compatible backup target, such as MinIO, must be added before Authentik database restore is considered fully protected again.

## DR Restore Mode (opt-in)

To restore from object storage, switch this app to the `dr-restore` overlay in Git and sync:

- Overlay path: `kubernetes/infrastructure/controllers/authentik-db-prereqs/overlays/dr-restore`

This keeps disaster recovery explicit and avoids recovery bootstrap loops during normal installs.

Historical R2 backup path contract:

- historical live cluster backups wrote to `s3://rosenvall-homelab-backup/authentik/live/`
- the DR overlay restores from that live path
- a cluster running in DR mode writes to `s3://rosenvall-homelab-backup/authentik/dr/`
- the live cluster no longer writes new base backups or WAL archives to those paths in default mode

Do not reuse the same backup prefix for a fresh `initdb` cluster and a DR-restored cluster. Mixing archive histories can cause WAL replay conflicts during recovery.
