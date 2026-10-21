# kingsguard

Kingsguard, a co-op lane-defence autobattler (repo `carnufex/kingsguard`): one container serves the
client build and the co-op WebSocket server (`/ws`) on port 8080. Public at
https://kingsguard.rosenvall.se through `gateway/external`. The game has no accounts: anyone with the URL can
open a lobby, and anyone with a room code can join it.

- **Image:** `ghcr.io/carnufex/kingsguard:sha-<git-short>@sha256:…`, built by the game repo's CI on every push to
  its `main` (GitHub-hosted), which also bumps `deployment.yaml` here (commits `kingsguard: deploy sha-…`).
  Older hand-built images are in `registry.rosenvall.se/carnufex/kingsguard`.
- **Pull secret:** `kingsguard-image-pull` (ExternalSecret over Bitwarden `GHCR_PAT` and `registry-password`).
- **Storage:** `kingsguard-data`, 1 Gi Longhorn RWO, holds the SQLite campaign saves (`/data/kingsguard.db`).
- **One replica, `Recreate`:** rooms live in memory and SQLite has one writer. A rollout closes open rooms;
  campaigns are saved after every action and round, so a party reloads and rejoins.
- **Backup:** `kubectl -n kingsguard exec deploy/kingsguard -- cat /data/kingsguard.db > kingsguard.db`
  (stop play first, or the copy may miss the WAL).
