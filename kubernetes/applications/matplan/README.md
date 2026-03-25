# MatPlan Scaffold

MatPlan is intentionally scaffold-only in this repo until the runtime artifacts are real and reproducible.

## Current State

The folder keeps the intended Kubernetes manifests for:

- `api-deployment.yaml` + `api-service.yaml`
- `frontend-deployment.yaml` + `frontend-service.yaml`
- `httproute.yaml` for `matplan.rosenvall.se`
- `externalsecret.yaml` for runtime secrets
- `configmap.yaml` for non-secret runtime configuration
- `database.yaml` for the application PostgreSQL cluster
- `data-protection-pvc.yaml` for ASP.NET Data Protection keys

Only the smallest safe shape is currently active in `kustomization.yaml`:

- namespace
- config map
- data protection PVC
- database bootstrap secret
- PostgreSQL cluster

The runtime resources stay out of sync until all prerequisites below are satisfied.

## Blockers Before Enabling Runtime

- Publish real GHCR images for both API and frontend
- Replace `sha-REPLACE_ME` in the deployment manifests
- Ensure Bitwarden secret IDs in `externalsecret.yaml` remain valid
- Verify health probes and app startup in-cluster
- Re-add `externalsecret.yaml`, deployments, services, and `httproute.yaml` to `kustomization.yaml`

## Secret Contract

The API code requires these runtime secrets in production:

- `ConnectionStrings__MatPlan`
- `Jwt__SigningKey`
- `GoogleAuth__ClientSecret`

These are currently sourced from the dedicated Bitwarden project for MatPlan via
`ClusterSecretStore/bitwarden-secretsmanager-matplan`.

The PostgreSQL bootstrap password is derived from the same Bitwarden
`ConnectionStrings__MatPlan` secret through `database-bootstrap-secret.yaml`,
so the database owner password and application connection string stay aligned.

`GoogleAuth__ClientId` and `GoogleAuth__RedirectUri` are configured in `configmap.yaml`.

These values are configuration, not secrets, and belong in `configmap.yaml`:

- `GoogleAuth__ClientId`
- `GoogleAuth__RedirectUri`

If Google sign-in is not enabled yet, the API can still start without a configured Google client.

## Routing Note

`matplan.rosenvall.se` already resolves through Cloudflare, so DNS is not the current blocker.
The blocker is that the app runtime is still placeholder-based and cannot become healthy yet.

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
