# Authentik DB Prereqs

This app contains the Authentik namespace, runtime secrets, and CloudNativePG cluster.

## Default Mode

The default manifest uses `initdb` for deterministic new cluster bootstrap.

## DR Restore Mode (opt-in)

To restore from object storage, switch this app to the `dr-restore` overlay in Git and sync:

- Overlay path: `kubernetes/infrastructure/controllers/authentik-db-prereqs/overlays/dr-restore`

This keeps disaster recovery explicit and avoids recovery bootstrap loops during normal installs.
