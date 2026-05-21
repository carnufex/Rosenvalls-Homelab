# Rosenvall DevOps

Rosenvall DevOps is routed through `gateway/internal` at `https://devops.rosenvall.se`.

Runtime shape:

- `rosenvall-devops-frontend` serves the React app and proxies `/api` and `/hubs` to the API service.
- `rosenvall-devops-api` stores demo state in SQLite on `PVC/rosenvall-devops-state`.
- Codex execution is still enabled, but `Ai__Codex__ImplementationBypassSandbox` must stay `false`.
- Auth is handled by Authentik OIDC using the `rosenvall-devops` public client.
- Preview orchestration uses the app service account with a ClusterRole for preview namespaces and preview resources.

The app intentionally uses SQLite for the May 2026 demo. Move it to CloudNativePG before treating the state as production data.

Storage:

- `rosenvall-devops-state`: `longhorn-critical`, stores SQLite demo state.
- `rosenvall-devops-codex-home`: `longhorn`, stores runtime Codex home data.

Secrets:

- `ExternalSecret/rosenvall-devops-ghcr` reads from `ClusterSecretStore/bitwarden-secretsmanager-rosenvall-devops`.
- That store is limited by External Secrets namespace conditions to `rosenvall-devops`.
- It still uses the shared bootstrap `bitwarden-access-token`; move the GHCR PAT to a dedicated Bitwarden project/token before treating this as strict secret isolation.

Security notes:

- The route should stay on `gateway/internal`. Do not attach it to `gateway/external` without a separate review.
- The preview manager remains a ClusterRole because the current preview flow creates and deletes namespaces.
- `pods/log` is intentionally not granted. Add it back only if the app has a documented log-viewing feature that needs it.
- Keep Codex sandbox enforcement enabled; do not set `Ai__Codex__ImplementationBypassSandbox` to `true`.
- API and frontend containers disallow privilege escalation and use the runtime default seccomp profile. The frontend keeps only `CHOWN`, `SETGID`, and `SETUID` because the current nginx entrypoint chowns cache directories and starts workers as UID/GID 101; remove those exceptions after the image is rebuilt to avoid startup chown/setuid.
- `runAsNonRoot` is not forced yet because the current image user contract is not documented; add it after the GHCR images are verified to run as a non-root UID.
