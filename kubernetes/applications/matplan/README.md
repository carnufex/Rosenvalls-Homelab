# MatPlan Testmiljö

MatPlan kör i homelabbet som testmiljö medan lokal Docker Compose fortsätter vara utvecklingsflödet.

## Resurser i den har mappen

- `api-deployment.yaml` + `api-service.yaml`
- `frontend-deployment.yaml` + `frontend-service.yaml`
- `httproute.yaml` för `matplan.rosenvall.se`
- `configmap.yaml` med icke-hemlig runtime-konfiguration
- `externalsecret.yaml` för runtime-hemligheter via Bitwarden
- `data-protection-pvc.yaml` för ASP.NET Data Protection-nycklar

## Image-taggar

Deployment-filerna pekar på `sha-REPLACE_ME`. Uppdatera till en publicerad GHCR-tagg från MatPlan-pipelinen:

- `ghcr.io/carnufex/matplan-api:sha-<commit>`
- `ghcr.io/carnufex/matplan-frontend:sha-<commit>`

## Bitwarden-krav

`externalsecret.yaml` innehåller placeholders för remote nyckel-id:n. Byt dem till riktiga Bitwarden item-id:n innan sync:

- `ConnectionStrings__MatPlan`
- `Jwt__SigningKey`
- `GoogleAuth__ClientId`
- `GoogleAuth__ClientSecret`

## Driftantaganden

- API kör som `ASPNETCORE_ENVIRONMENT=Staging`.
- `GoogleAuth__RedirectUri` är satt till `https://matplan.rosenvall.se/api/auth/google/callback`.
- `RecipeAssistant` och `VoiceAssistant` är initialt avstängda i testmiljön.
- Databas bootstrap/seed är avstängd i testmiljön (`Database__ApplyMigrations=false`, `Database__SeedDemoData=false`).
