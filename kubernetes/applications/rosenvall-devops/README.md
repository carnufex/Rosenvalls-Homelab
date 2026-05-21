# Rosenvall DevOps

Rosenvall DevOps is currently routed through the internal gateway at `https://devops.rosenvall.se`.

Runtime shape:

- `rosenvall-devops-frontend` serves the React app and proxies `/api` and `/hubs` to the API service.
- `rosenvall-devops-api` stores demo state in SQLite on `PVC/rosenvall-devops-state`.
- Auth is handled by Authentik OIDC using the `rosenvall-devops` public client.
- Preview orchestration uses the app service account with RBAC limited to preview namespaces and preview resources.

The app intentionally uses SQLite for the May 2026 demo. Move it to CloudNativePG before treating the state as production data.
