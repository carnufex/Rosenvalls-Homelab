# Hub Central

`hub-central` stays local-only in v1 and is exposed directly through `gateway/internal`.

## Image Contract

- The image is pinned to the current local repo commit tag: `ghcr.io/carnufex/hub-central:sha-1796075`.
- The repo assumes GHCR pulls may require authentication, so this app reuses the same Bitwarden-backed `GHCR_PAT` pattern already used elsewhere in the homelab.

## Access Model

- `Service/hub-central` stays `ClusterIP`.
- `HTTPRoute/hub-central` binds the app to `gateway/internal` on `https://hub-central.rosenvall.local`.
- Add local DNS on the UDM so LAN clients resolve `*.rosenvall.local` to `192.168.1.220`.
- Internal HTTPS for `*.rosenvall.local` uses the cluster-local CA managed in the `gateway` namespace.
- The deployment runs at `replicas: 1`.
- No public `HTTPRoute` is created in v1.
