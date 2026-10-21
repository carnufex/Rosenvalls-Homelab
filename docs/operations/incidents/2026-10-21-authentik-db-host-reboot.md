# 2026-10-21 — authentik database corrupted by a Proxmox host reboot

**Impact:** authentik (SSO for every LAN/public app) down 19:04–19:33 UTC. Data since the nightly dump
(2026-10-20 23:05 UTC) lost: sessions, events, anything changed in the admin UI that day. Config from
blueprints was re-applied automatically (42/42 successful). Every other database recovered by itself.

## What happened

- update-center *Proxmox → Uppdatera alla* rebooted host `desktop` (packages: new PVE kernel).
- `desktop` runs **control-01 and all three Longhorn workers (worker-01, -02, -03)**. Every 2-replica
  Longhorn volume therefore had both replicas on that one host.
- The run drained the host's nodes, but the authentik Postgres pod ran on another node; its volumes
  stayed attached with both replicas on `desktop`.
- Proxmox shuts the VMs down one after another. The engine kept writing to the replica still up; then
  that one went too (19:04:25, both replicas "in error"). After the reboot Longhorn auto-salvaged a
  replica that had stopped first and missed the last writes.
- Postgres: `invalid checkpoint record` / `could not locate a valid checkpoint record` (pg_control on the
  data volume pointed into WAL the WAL volume never got) → crash loop.
- lots, cmdb, ngm, immich Postgres and gatebound MariaDB crashed too and recovered normally
  (crash recovery; `mariadb-check --all-databases` clean).

## Recovery

1. Old PVs kept (`Retain`, label `homelab.rosenvall.se/incident=authentik-wal-corruption-20261021`):
   `pvc-acdd7378-…` (data) and `pvc-889cb962-…` (WAL). Delete them once nobody needs them for analysis.
2. Deleted `Cluster/authentik-postgresql`; ArgoCD recreated it with `initdb` (new app password secret).
3. `pg_restore --no-owner --role=authentik` of `authentik-2026-10-20T230501Z.dump` into
   `authentik_restore`, then `ALLOW_CONNECTIONS false` + terminate + rename (`authentik` ⇄
   `authentik_empty_20261021`) so the pods never saw a half-restored database. The empty one can be dropped.
4. `rollout restart` of authentik server and worker.

## Fixes

- update-center (sha-aba9c51): a host reboot is **refused** when the host holds every healthy replica
  (2+) of an attached volume; the fleet run installs the packages, skips that reboot and goes on.
  Single-replica volumes are only logged (nothing to diverge). Talos node upgrades log the same.
- Rebooting `desktop` now needs a planned window with the storage workloads stopped
  (scale to 0 / CNPG hibernation) — or, better, Longhorn replicas spread over more than one host.

## Open risk

All Longhorn replicas live on one physical machine (`desktop`, also the host under suspicion for
non-ECC RAM bit flips since 2026-10-11). A hardware fault there loses every replica at once; the only
copies elsewhere are the nightly dumps and the daily Longhorn backups on host1 NFS.
