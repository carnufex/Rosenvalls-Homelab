# BikePal

BikePal is deployed here as a three-workload app. It is not publicly routed until
it has native Authentik/OIDC support or an approved Authentik proxy exception:

- `bikepal-frontend` serves `/`
- `bikepal-api` serves `/api`
- `bikepal-worker` processes background jobs and road-network imports

The folder mirrors the `matplan` app structure while adding the storage and PostGIS pieces BikePal needs.

## Current State

The folder contains:

- namespace, config map, runtime secret sync, services, and deployments
- `database.yaml` for a dedicated CloudNativePG PostgreSQL/PostGIS cluster
- `data-protection-pvc.yaml` for shared ASP.NET Data Protection keys
- `road-network-pvc.yaml` for mounted road-network source files such as GeoJSON and Sweden OSM PBF extracts

## Secret Contract

BikePal uses a dedicated Bitwarden-backed secret store for runtime secrets:

- `ClusterSecretStore/bitwarden-secretsmanager-bikepal`
- `ExternalSecret/bikepal-secrets`
- `ExternalSecret/bikepal-postgresql-bootstrap`

The intended runtime secret keys are:

- `Database__ConnectionString`
- `Strava__ClientId`
- `Strava__ClientSecret`

The PostgreSQL bootstrap secret is derived from the same `Database__ConnectionString` value through
`database-bootstrap-secret.yaml`, so the CNPG owner password and the application connection string stay aligned.

Private GHCR pulls use the shared Homelab `ClusterSecretStore/bitwarden-secretsmanager`.
`ExternalSecret/bikepal-ghcr` renders the `bikepal-ghcr` docker config secret for
`ServiceAccount/bikepal-runtime`.

## Routing Contract

There is intentionally no public `HTTPRoute` for BikePal. The manifests still
keep the production `.rosenvall.se` OAuth and frontend settings so the app can be
re-enabled without changing app config after Authentik protection is added.

When public access is restored, route:

- `/api` to `Service/bikepal-api`
- `/` to `Service/bikepal-frontend`

The dedicated standalone frontend is the intended public root, and the old `/ui`
entrypoint is intentionally not part of this deployment contract.

## Database Contract

`database.yaml` provisions a dedicated CNPG cluster named `bikepal-postgresql` with a PostGIS-enabled operand image and
bootstraps the core extensions in `template1` during init:

- `postgis`
- `postgis_topology`
- `fuzzystrmatch`

The application connection string in production should target `bikepal-postgresql-rw:5432`.

## Storage Contract

`bikepal-data-protection` is mounted into both API and worker at `/var/bikepal/data-protection` so Strava tokens and
OAuth state remain decryptable across hosts.

`bikepal-road-network` is mounted read-only into both API and worker at `/data/road-network`. The app expects the same
paths as local Docker:

- `/data/road-network/sample-stockholm.geojson`
- `/data/road-network/sweden-latest.osm.pbf`

## Runbook

### 1. Keep secret references and image digests current

When rotating secrets or publishing new images, keep these manifests aligned:

- `externalsecret.yaml`: runtime secret item IDs for BikePal
- `database-bootstrap-secret.yaml`: the connection-string item ID used to derive the CNPG bootstrap secret
- `ghcr-image-pull-secret.yaml`: the shared Homelab `GHCR_PAT` reference
- `api-deployment.yaml`
- `frontend-deployment.yaml`
- `worker-deployment.yaml`

The deployment manifests should stay pinned to immutable GHCR digests and be updated by the BikePal publish workflow
when new images are published.

The production frontend image is expected to come from `apps/bikepal-app/Dockerfile.prod`, not the local-development Vite
server image contract in `apps/bikepal-app/Dockerfile`.

### 2. Seed the road-network PVC

For the built-in sample dataset, copy `sample-stockholm.geojson` into the mounted PVC as:

- `/data/road-network/sample-stockholm.geojson`

For a full Sweden import, copy a local `.osm.pbf` extract into the same PVC as:

- `/data/road-network/sweden-latest.osm.pbf`

A practical pattern is:

1. Create a temporary pod in the `bikepal` namespace that mounts `PersistentVolumeClaim/bikepal-road-network`.
2. `kubectl cp` the local file into `/data/road-network/`.
3. Delete the temporary pod after the copy completes.

### 3. Large Sweden seed guidance

Whole-Sweden `.osm.pbf` files are large enough that they should be staged once into the PVC and reused across worker restarts.
Do not rely on image rebuilds or init containers for that payload. Keep a few gigabytes of headroom beyond the source file size
for alternate extracts and operational slack. If you expect to keep multiple regional extracts or alternate Sweden files around
at once, increase `road-network-pvc.yaml` beyond the v1 default of `10Gi` before syncing.

### 4. Queue imports after the app is live

Sample GeoJSON import after public access is restored:

```powershell
Invoke-RestMethod `
  -Method Post `
  -Uri https://bikepal.rosenvall.se/api/road-network/imports `
  -ContentType 'application/json' `
  -Body '{"sourceName":"sample-stockholm"}'
```

Whole-Sweden PBF import after public access is restored:

```powershell
Invoke-RestMethod `
  -Method Post `
  -Uri https://bikepal.rosenvall.se/api/road-network/imports `
  -ContentType 'application/json' `
  -Body '{"sourceName":"sweden-osm","sourceFormat":"pbf"}'
```

Signed-in upload for smaller files after public access is restored:

```powershell
$form = @{
  sourceName = 'gavle-extract'
  sourceFormat = 'geojson'
  file = Get-Item '.\gavle.geojson'
}

Invoke-RestMethod `
  -Method Post `
  -Uri https://bikepal.rosenvall.se/api/road-network/uploads `
  -Form $form
```

## Runtime Assumptions

- BikePal runs as `Staging` in Kubernetes for both API and worker
- `Strava__RedirectUri` is `https://bikepal.rosenvall.se/api/auth/strava/callback`
- `Frontend__AppBaseUrl` is `https://bikepal.rosenvall.se`
- Longhorn RWX volumes are available for the shared data-protection and road-network PVCs
- `Valhalla__BaseUrl` stays a placeholder until a cluster-local Valhalla service is wired in
