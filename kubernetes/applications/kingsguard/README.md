# kingsguard

Kingsguard, a co-op lane-defence autobattler (repo `carnufex/kingsguard`): one container serves the
client build and the co-op WebSocket server (`/ws`) on port 8080. Public at
https://kingsguard.rosenvall.se through `gateway/external`. The game has no accounts: anyone with the URL can
open a lobby, and anyone with a room code can join it.

- **Image:** `registry.rosenvall.se/carnufex/kingsguard:sha-<git-short>@sha256:…`, built and pushed by hand
  from a clean worktree of the game repo (its `deploy/README.md`). Update: push a new tag, bump
  `deployment.yaml`, push this repo.
- **Pull secret:** `kingsguard-image-pull` (ExternalSecret over the shared Bitwarden `registry-password`).
- **Storage:** `kingsguard-data`, 1 Gi Longhorn RWO, holds the SQLite campaign saves (`/data/kingsguard.db`).
- **One replica, `Recreate`:** rooms live in memory and SQLite has one writer. A rollout closes open rooms;
  campaigns are saved after every action and round, so a party reloads and rejoins.
- **Backup:** `kubectl -n kingsguard exec deploy/kingsguard -- cat /data/kingsguard.db > kingsguard.db`
  (stop play first, or the copy may miss the WAL).
