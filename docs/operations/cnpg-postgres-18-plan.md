# CNPG: bullseye images → trixie, then PostgreSQL 17 → 18

Plan, 2026-10-22. In progress (see *Progress*). One database at a time, a fresh dump before every step. Facts below were
checked against the live cluster and the images on that date.

## Progress

| Date | Cluster | Step | Result |
|---|---|---|---|
| 2026-10-22 | cmdb | phase 1 (`8ccf844`) | 17.5 bullseye → 17.11 trixie, postgis 3.5.2 → 3.6.4. Down ~3.5 min (smart shutdown, see below). Row counts of the 8 largest tables, 121 tables and `ST_Extent` of all 22 geometry columns identical before/after. cmdb-api Ready again the moment the DB was. Dump job on `17-standard-trixie` verified (119 MB). Pre-step dump `cmdb-2026-10-22T120028Z.dump` also off-cluster. |
| 2026-10-22 | lots | phase 1 (`0feeac4`) | 17.10 bullseye → 17.11 trixie, pgvector 0.8.2 → 0.8.7. Down ~3 min (smart shutdown). Row counts of all 58 tables identical; a 5-nearest-neighbour query through the HNSW index (`knowledge_chunks_vec_1024`) returned the same ids and distances. lots Ready 5 s after the DB; `/health/ready` 200. Dump job on `17-standard-trixie` verified (70 MB). Pre-step dump `lots-2026-10-22T125503Z.dump` also off-cluster. |

Lesson (corrected after lots): the downtime is **not** the image pull. The image was already on the node, and
the pod was rescheduled to another node anyway, so pre-pulling on the old node does not help. It is CNPG's
smart shutdown: Postgres waits for client sessions to end until `smartShutdownTimeout` (default 180 s), and the
apps' connection pools never close them (lots: `Killing` 12:56:20, down until ~12:59:06). For ngm and
authentik, add `smartShutdownTimeout: 15` to the Cluster in the same commit as the image change. After 15 s
the shutdown switches to fast mode, which is still a clean shutdown with a checkpoint, and the restart drops
to well under a minute.

## Why

- All four clusters run the bare tags `postgresql:17` / `postgis:17-3.5`. These are **Debian 11 bullseye**
  images: frozen, slated for removal, and bullseye is out of support. Bare `:18` is bullseye too, so going
  straight to 18 would land on the same dead base.
- The supported images are `<major>-standard-{bookworm,trixie}` (PostGIS: `<major>-3.6-standard-…`).
- PostgreSQL 18 is the current major (18.6). CNPG 1.30.1 (running) does declarative in-place major upgrades
  with `pg_upgrade --link` when `spec.imageName` changes major.

## Current state (live, 2026-10-22)

| Cluster | Ns | Inst. | Image → running version | Extensions | DB size | Dump job |
|---|---|---|---|---|---|---|
| authentik-postgresql | authentik | 1 | `postgresql:17` → 17.11 | — | 237 MB | `authentik-db-ops/db-dump.yaml` (nightly → host1 NFS) |
| cmdb-postgresql | cmdb | 1 | `postgis:17-3.5` → **17.5** | postgis 3.5.2, pg_trgm 1.6 | 3.3 GB (synthetic data) | `cmdb/db-dump.yaml` |
| lots-postgresql | lots | 1 | `postgresql:17` → 17.10 | vector 0.8.2 (declarative `Database.extensions`) | 26 MB | `lots/db-dump.yaml` |
| ngm-postgresql | ngm | 2 | `postgresql:17` → 17.11 | — | 9 MB | `ngm/db-backup-cronjob.yaml` (→ OneDrive) |

Verified, no blockers:

- **Collations:** every database is `C` (libc), and no column uses another collation. The glibc jump
  bullseye → trixie cannot change sort order, so no index rebuilds are needed.
- **Target images exist and carry the extensions:** `postgresql:{17,18}-standard-trixie` (18.6) have
  pg_trgm and pgvector 0.8.7. `postgis:{17,18}-3.6-standard-trixie` have postgis 3.6.4, pg_trgm and
  pgvector.
- **Data checksums are off on all clusters.** PG18's `initdb` enables them by default, but the CNPG
  upgrade job reads the state from `pg_controldata` and passes the matching flag (`tryAddDataChecksums`,
  `internal/cmd/manager/instance/upgrade/execute/cmd.go`, v1.30.1). Upgraded clusters stay without
  checksums; turning them on later is a separate offline `pg_checksums --enable`.
- **cmdb runs 17.5:** 17.0–17.5 have a `pg_upgrade` bug when `max_slot_wal_keep_size` ≠ -1. The repo does
  not set it, and phase 1 moves cmdb to 17.11 anyway.
- **Drivers:** lots and cmdb use Npgsql 10.0.3, ngm uses node-pg 8.x, and authentik is Django/psycopg.
  None of them depends on the server major. Authentik on 18 is still verified in the rehearsal (step R).

## Rules for every step

1. **Gate:** all Longhorn volumes healthy, no update-center job running, and no Proxmox `desktop` reboot
   pending (see `incidents/2026-10-21-authentik-db-host-reboot.md`). Not on the same day as host work.
2. **Fresh dump first.** Run `kubectl -n <ns> create job --from=cronjob/<dump-cronjob> pre-<step>-<date>`,
   wait for it to complete, copy the file off-cluster, and check it with `pg_restore -l`.
3. **One cluster per commit.** The `imageName` change and the dump job image (it must match the server
   major) go in the same commit; ArgoCD syncs it. Watch until the cluster is `Cluster in healthy state`,
   then check the app.
4. **Order:** cmdb (synthetic data) → lots → ngm (two instances) → authentik (SSO, most critical, last).
   Wait at least one nightly dump cycle between clusters in phase 2.

## Phase 1 — same major (17), bullseye → trixie

A minor/OS image change: CNPG rolls the instances (ngm: replica first, then switchover). The data
directory is untouched, so rollback is reverting `imageName`.

| Cluster | `imageName` → | Extra steps | Downtime |
|---|---|---|---|
| cmdb | `ghcr.io/cloudnative-pg/postgis:17-3.6-standard-trixie` | after the restart: `ALTER EXTENSION postgis UPDATE;` (3.5.2 → 3.6.4); check `SELECT postgis_full_version();` | ~1 min |
| lots | `ghcr.io/cloudnative-pg/postgresql:17-standard-trixie` | `ALTER EXTENSION vector UPDATE;` (0.8.2 → 0.8.7); the declarative `Database` keeps `ensure: present` | ~1 min |
| ngm | same as lots | — | seconds (switchover) |
| authentik | same as lots | also update `overlays/dr-restore/{database,authentik-restore.example}.yaml` | ~1 min |

Each phase-1 commit also changes the cluster's dump job image to `postgresql:17-standard-trixie`.

**Done when:** all four run 17.11 on trixie, extensions updated, apps green, and a nightly dump completed on
the new image.

## Step R — rehearsal of the major upgrade (before phase 2)

On a throwaway cluster, never on the live ones:

1. Create namespace `cnpg-rehearsal` with a `Cluster` built by `bootstrap.initdb.import`
   (`type: microservice`) from the live cluster, on its phase-1 image. Use storageClass `longhorn-single`
   and the smallest size that fits. Longhorn is near its scheduling limit (worker-02 has 179 of 180 GiB
   scheduled): check `kubectl -n longhorn-system get nodes.longhorn.io` first, and prefer one rehearsal at
   a time.
2. Change its `imageName` to the 18 image and watch the upgrade job (`kubectl -n cnpg-rehearsal get jobs,pods -w`).
3. Check `SELECT version();`, `\dx`, row counts against the source, and `show data_checksums` (still `off`).
4. For authentik: point a temporary authentik (or `ak` from the server image) at the rehearsal DB and run
   its migrations check. This verifies authentik 2026.8 on 18.
5. Delete the namespace.

Do it once per extension profile: cmdb (postgis), lots (vector), and authentik (plain, also covers ngm).

## Phase 2 — 17 → 18 in place

What CNPG does: stops **all** pods, runs a job with `pg_upgrade --link` on the primary's volumes, swaps the
directories, starts the primary, and **re-clones** replicas (ngm). The whole cluster is down for the
duration (seconds to a few minutes at these sizes). If the job fails, revert `imageName` to 17 and the
operator restarts on the old data. After it succeeds, rollback means restoring the pre-step dump into a
fresh cluster.

| Cluster | `imageName` → | Extra steps |
|---|---|---|
| cmdb | `ghcr.io/cloudnative-pg/postgis:18-3.6-standard-trixie` | — (postgis already 3.6.4 on both sides) |
| lots | `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie` | — (vector 0.8.7 on both sides) |
| ngm | same as lots | replica re-clone (9 MB, quick) |
| authentik | same as lots | plus the DR overlay files |

In the same commit: dump job image → `postgresql:18-standard-trixie`.

After each cluster:

- `vacuumdb --all --analyze-in-stages --missing-stats-only`. PG18 `pg_upgrade` keeps planner statistics;
  this fills in what is missing (extended stats).
- Check the app. Run the dump job by hand and confirm the file restores (`pg_restore -l`).
- Old logical dumps stay valid (restorable into 18). There is no PITR across the major boundary, which does
  not matter here because there is no WAL archiving.

**Done when:** all four run 18.x on trixie, apps green, and one nightly dump cycle completed for each.

## Cleanup from the 2026-10-21 incident (any time)

- `DROP DATABASE authentik_empty_20261021;` on authentik-postgresql. It is the empty database that was
  swapped out during the restore.
- Retained PVs `pvc-acdd7378-…` and `pvc-889cb962-…` (label
  `homelab.rosenvall.se/incident=authentik-wal-corruption-20261021`): delete them once nobody needs them.
  They take Longhorn capacity, which phase R needs.

## Effort

Phase 1 is about 20 min per cluster including the dump (≈1.5 h). Step R is about 1 h. Phase 2 is about
30 min per cluster (≈2 h), spread over at least four days because of the nightly-dump wait between
clusters.
