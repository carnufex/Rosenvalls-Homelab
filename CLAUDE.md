# Rosenvalls-Homelab — Claude Guide

The full agent guide lives in `AGENTS.md` and is the source of truth for cluster
architecture, the critical Bitwarden bootstrap secret, troubleshooting order, and
routing conventions. Read it:

@AGENTS.md

## Claude skills (read before non-trivial cluster/app work)

Project skills live in `.claude/skills/` and Claude loads them on demand by their
descriptions. Reach for:

- **cluster-diagnostics** — anything broken/degraded/unreachable in the cluster.
  Walk the chain top-down (secrets → ArgoCD → routing/certs → app).
- **cloudflare-gateway-routing** — public ingress for `*.rosenvall.se`, Cloudflare
  5xx (esp. 530), TLS/cert issues, or adding/changing a public `HTTPRoute`.
- **gitops-app-onboarding** — adding a new app under `kubernetes/applications/`.

The legacy Codex versions remain in `.codex/skills/` for the Codex CLI; the
`.claude/skills/` copies are the maintained, expanded versions for Claude.

## Working norms

- GitOps-first: the cluster syncs from `origin`. A change applied only with
  `kubectl` will be reverted by ArgoCD — push it to the repo.
- Manifests live under `kubernetes/`, not `k8s/`.
- Keep bootstrap-only and break-glass secrets out of Git.
- Access the cluster via `$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"`.
