# MatPlan

MatPlan runtime is enabled in this repo and pinned to immutable GHCR image digests.

## Current State

The folder contains:

- namespace, config map, runtime secret sync, services, deployments, route
- `database.yaml` for the application PostgreSQL cluster
- `data-protection-pvc.yaml` for ASP.NET Data Protection keys
- `whisper-*` and `piper-*` manifests for internal voice services used by the API

## Secret Contract

The API code requires these runtime secrets in production:

- `ConnectionStrings__MatPlan`
- `Jwt__SigningKey`
- `GoogleAuth__ClientSecret`

These are sourced from the dedicated Bitwarden project for MatPlan via
`ClusterSecretStore/bitwarden-secretsmanager-matplan`.

The PostgreSQL bootstrap password is derived from the same Bitwarden
`ConnectionStrings__MatPlan` secret through `database-bootstrap-secret.yaml`,
so the database owner password and application connection string stay aligned.

`GoogleAuth__ClientId` and `GoogleAuth__RedirectUri` are configured in `configmap.yaml`.

These values are configuration, not secrets, and belong in `configmap.yaml`:

- `GoogleAuth__ClientId`
- `GoogleAuth__RedirectUri`

If Google sign-in is not enabled yet, the API can still start without a configured Google client.

## Voice Runtime

`matplan-whisper` runs the `ghcr.io/ggml-org/whisper.cpp:main` image and stores the
downloaded `kb-large` model in `matplan-whisper-models`.

`matplan-piper` runs a GHCR image built from `docker/piper/Dockerfile` and stores
downloaded voices in `matplan-piper-data`.

Both services are cluster-internal only. `matplan-config` points the API to:

- `http://matplan-whisper:8080`
- `http://matplan-piper:5000`
- `http://ollama.ollama.svc.cluster.local:11434`

## Image Contract

The live manifests use immutable GHCR digests rather than floating tags.
For `carnufex/MatPlan`, the publish workflow updates these deployment manifests automatically
after a successful GHCR publish and commits the new digests back to this repository using
a write-enabled deploy key scoped to `Rosenvalls-Homelab`.

If automation is unavailable, update the deployment manifests manually with the new immutable
GHCR digests and let ArgoCD sync the resulting Git change.

Private GHCR pulls use `ExternalSecret/matplan-ghcr`, which sources the `GHCR_PAT`
from the Homelab Bitwarden project and renders a `kubernetes.io/dockerconfigjson`
secret for `ServiceAccount/matplan-runtime`.

`matplan-piper` is currently a placeholder image reference until the Dockerfile has
been published to GHCR and pinned to a digest. The deployment is wired for that future
image contract, but it will not become Ready until the image exists.

## Runtime Assumptions

- API runs as `ASPNETCORE_ENVIRONMENT=Staging`
- `GoogleAuth__RedirectUri` is `https://matplan.rosenvall.se/api/auth/google/callback`
- `GoogleAuth__ClientId` targets the MatPlan production OAuth client
- `RecipeAssistant` and `VoiceAssistant` start disabled
- Database schema bootstrap stays enabled until MatPlan gets real migrations (`Database__ApplyMigrations=true`, `Database__SeedDemoData=false`)

## Database Bootstrap

`database.yaml` provisions a dedicated CloudNativePG cluster named `matplan-postgresql`.
`database-bootstrap-secret.yaml` creates the CNPG `basic-auth` bootstrap secret from the
existing Bitwarden `ConnectionStrings__MatPlan` value, keeping the database contract
deterministic across rebuilds.
