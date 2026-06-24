# Gatebound (OTLife) — Forgotten Server + website

Onboarding of the Gatebound-2d game (source repo `D:\Github\Gatebound-2d`) into
the cluster. Mirrors the game's `docker-compose.yml`. Plain kustomize (not Helm)
to match the rest of `kubernetes/applications/`.

## Components

| Component | Image | Ports | Status |
|---|---|---|---|
| **mariadb** | `mariadb:11.4` (public) | 3306 (in-cluster) | ✅ deployed |
| **tfs** (Forgotten Server) | `ghcr.io/carnufex/gatebound-tfs` (to build) | 7171 login/status, 7172 game — **TCP** | ⏳ needs image |
| **web** (Next.js + WASM client `/play`) | `ghcr.io/carnufex/gatebound-web` (to build) | 3000 HTTP | ⏳ needs prod image |
| **web-bridge-login/game** (websockify) | `python:3.12-alpine` (public) | ws 7191→7171, 7192→7172 | ⏳ depends on tfs |

## What is live now

Only **MariaDB**. It is a real, public image so it meets the onboarding bar
(image + secrets confirmed). It comes up with the Forgotten Server schema and GM
seed loaded from `db-init/` (mounted to `/docker-entrypoint-initdb.d`, runs once
on an empty data volume).

- Storage: `gatebound-mariadb-data` PVC, 5Gi, longhorn.
- Service: `mariadb.gatebound.svc.cluster.local:3306` (what TFS/web connect to).
- DB name/user: `forgottenserver` / `forgottenserver`.

## Secrets (Bitwarden, homelab project — never in Git)

`ExternalSecret/gatebound-mariadb` → secret `gatebound-mariadb` with
`MARIADB_*` env. Passwords are generated, not the weak compose defaults:

- `gatebound-db-root-password` — UUID `6dda7d4d-1ab7-4daa-af38-b47300f6bc89`
- `gatebound-db-password` (forgottenserver user) — UUID `2b92ef0d-0979-4255-b4bf-b47300f6bcbe`

**Note:** the game's `server-config/config.lua` hardcodes `mysqlPass = "forgotten"`.
When TFS is onboarded, inject the real password from the secret instead (init
container running `envsubst` over `config.lua`, or a TFS fork that reads env) —
do **not** commit the password into a ConfigMap.

## Routing plan

- **TFS game protocol is TCP**, not HTTP — it can NOT use an `HTTPRoute`. Expose
  it with a `Service: type=LoadBalancer` (Cilium LB-IPAM hands out a LAN IP) for
  the native OTClient, or a Cilium `TCPRoute` on the gateway. Set `ip` /
  advertised port in `config.lua` to the exposed address.
- **Website is HTTP** → `HTTPRoute` for `gatebound.rosenvall.se` (public via
  `gateway/external`, per the cloudflare-gateway-routing skill) or
  `gatebound.rosenvall.local` (internal). Add **last**, after health checks pass.
- **Browser WASM client** needs the websockify bridges fronted by **TLS (wss://)** —
  a gateway TLS listener or the existing `proxy/` reverse proxy. The web client's
  advertised ws endpoints must be the public wss addresses.

## To publish (do this in the Gatebound-2d session)

The TFS and web images are not built/published yet, so their manifests are
staged (commented) in `kustomization.yaml`.

1. **TFS image** — build from `forgottenserver-downgrade-1.8-8.60/Dockerfile`
   (Ubuntu 24.04 + vcpkg C++ build; bakes `data/`) and push to
   `ghcr.io/carnufex/gatebound-tfs:<tag>`. Add a GitHub Actions workflow.
2. **Web image** — there is only `web/Dockerfile.dev` (next dev, bind-mounts).
   Add a **production** Dockerfile (`next build` + `next start`, multi-stage) and
   push to `ghcr.io/carnufex/gatebound-web:<tag>`.
3. Both are private → this repo needs a `ghcr-image-pull-secret.yaml`
   ExternalSecret (copy the bikepal/matplan pattern).

## To finish onboarding (back here, after images exist)

1. Add `tfs-config-configmap.yaml` (config.lua: `mysqlHost=mariadb`, port 3306,
   password injected from the secret), `tfs-deployment.yaml`, `tfs-service.yaml`
   (LoadBalancer 7171/7172).
2. Add `web-deployment.yaml` (+ DB env from the secret), `web-service.yaml`, and
   the websockify `web-bridges-deployment.yaml`.
3. Uncomment the staged entries in `kustomization.yaml`, push, verify health.
4. Add the `HTTPRoute` (+ TLS for the ws bridges) **last**.

If anything fails to sync, use the **cluster-diagnostics** skill.
