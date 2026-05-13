# Authentik DB Prereqs

This app contains the Authentik namespace, runtime secrets, and CloudNativePG cluster.

## Current Stability Posture

The live cluster currently runs Authentik PostgreSQL as a single-instance cluster with
`20Gi` of WAL storage to prioritize service recovery over database HA. Restore a second
instance only after the primary is healthy and WAL growth is confirmed stable.

## Default Mode

The default manifest uses `initdb` for deterministic new cluster bootstrap.
`authentik-core-secrets` currently depends only on the existing Bitwarden
password field for the Authentik secret key and Redis password. Do not add
bootstrap admin fields to the ExternalSecret until the matching Bitwarden custom
fields exist; otherwise External Secrets cannot render the target Secret.

## DR Restore Mode (opt-in)

To restore from object storage, switch this app to the `dr-restore` overlay in Git and sync:

- Overlay path: `kubernetes/infrastructure/controllers/authentik-db-prereqs/overlays/dr-restore`

This keeps disaster recovery explicit and avoids recovery bootstrap loops during normal installs.

Backup path contract:

- normal live cluster backups write to `s3://rosenvall-homelab-backup/authentik/live/`
- the DR overlay restores from that live path
- a cluster running in DR mode writes to `s3://rosenvall-homelab-backup/authentik/dr/`
- the live cluster keeps a `7d` CNPG retention policy and compresses both base backups and WAL archives with `gzip`

Do not reuse the same backup prefix for a fresh `initdb` cluster and a DR-restored cluster. Mixing archive histories can cause WAL replay conflicts during recovery.
