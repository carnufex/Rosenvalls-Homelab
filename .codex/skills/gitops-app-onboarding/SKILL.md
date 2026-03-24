# GitOps App Onboarding

Use this guide when adding a new app under `kubernetes/applications/`.

## Rules

- Each top-level directory under `kubernetes/applications/` becomes its own ArgoCD app and namespace.
- Start with the smallest safe deployment shape.
- Do not add a public `HTTPRoute` until image names, secrets, and health checks are confirmed.
- Prefer public, immutable image tags or digests over `latest`.

## Recommended Onboarding Sequence

1. Create `kustomization.yaml`.
2. Create `ns.yaml`.
3. Add runtime manifests only after confirming images and secrets.
4. Add `HTTPRoute` last.
5. Document runtime dependencies and secret names in a local README.

## MatPlan-Specific Note

MatPlan currently needs more than a single image and should stay scaffold-only in this repo until GHCR publishing and a production frontend image exist.
