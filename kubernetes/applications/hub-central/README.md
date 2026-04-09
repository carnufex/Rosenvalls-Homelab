# Hub Central

`hub-central` stays local-only and is exposed on the internal gateway apex.

## Image Contract

- The image is pinned to a GHCR `sha-<commit>` tag from the separate `hub-central` repository.
- GHCR pulls may require authentication, so this app reuses the Bitwarden-backed `GHCR_PAT` pull-secret pattern already used elsewhere in the homelab.

## Access Model

- `Service/hub-central` stays `ClusterIP`.
- `HTTPRoute/hub-central` binds the app to `gateway/internal` on `https://rosenvall.local`.
- `HTTPRoute/hub-central-alias` keeps `https://hub-central.rosenvall.local` as a redirect alias back to the apex dashboard.
- LAN DNS should resolve both `rosenvall.local` and `*.rosenvall.local` to `192.168.1.220`.
- Internal HTTPS uses the cluster-local CA managed in the `gateway` namespace.
- The deployment runs at `replicas: 1`.
- No public `HTTPRoute` is created in v1.
