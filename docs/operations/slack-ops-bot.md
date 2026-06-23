# Slack Ops Bot — design

A Slack-driven operations bot for the homelab: Alertmanager posts a problem, the
bot attaches a suggested fix and action buttons, and a click (with confirmation)
remediates the cluster. Connects to Slack over **Socket Mode** — an outbound
WebSocket, so there is **no public endpoint and no inbound attack surface**.

## Why "powerful" here means GitOps-first

The cluster is fully GitOps (ArgoCD self-heals from `origin`). So the most
powerful *and* safe way for the bot to change almost anything is to operate on
the **Git repo**, not imperatively on the cluster. Two planes:

1. **GitOps plane (broad power, safe).** The bot commits/opens a PR to this repo
   (image bumps, replica/resource changes, new manifests, toggling apps).
   ArgoCD applies it. Every change is auditable (git history) and reversible
   (`git revert`). Imperative edits would just be reverted by self-heal anyway.
2. **Break-glass plane (scoped imperative).** For things Git cannot express —
   live remediation: rollout restart, reset a disposable PVC, delete a stuck
   pod, cordon/drain a node, trigger an ArgoCD sync/refresh, scale a workload,
   tail logs. A **curated verb set**, never arbitrary `kubectl`.

This gives "do most things" without ever granting a chat bot cluster-admin.

## Guardrails (non-negotiable)

- **Confirm every mutation** — two-step (click → confirm).
- **Protected namespaces** (`kube-system`, `longhorn-system`, `external-secrets`,
  `cnpg-system`, `authentik`, `gateway`, `cert-manager`, `argocd`): destructive
  ops are blocked or require typing a confirmation phrase.
- **Hard denylist:** delete CRDs/namespaces, edit/delete RBAC, read Secret
  values, `exec` into protected-namespace pods, or touch the bot's own
  resources/token.
- **No arbitrary `exec`** — exec is a cluster-takeover primitive; omit it, or
  restrict to an explicit pod allowlist and log every use.
- **Audit everything** — who clicked, when, what — to a Slack audit thread and a
  ring-buffer ConfigMap.
- **Read-only by default**; one concurrent mutating action; rate-limited.
- RBAC is an explicit ClusterRole of curated verbs — **never `*`**. The GitOps
  write path uses a repo-scoped GitHub token, so config changes need no cluster
  write at all. If the Slack token leaks, blast radius is the curated verb set,
  not the cluster.

## What the user provides (one-time)

Create a Slack app (https://api.slack.com/apps → From scratch), then:

- **Socket Mode:** enable it; generate an **app-level token** `xapp-…` with
  scope `connections:write`.
- **Bot token** `xoxb-…` with scopes: `chat:write`, `chat:write.public`,
  `commands` (and `files:write` if we want log snippets).
- Install the app to the workspace; invite the bot to the ops channel.
- A **GitHub fine-grained PAT** with `contents:write` (+ `pull_requests:write`)
  scoped to this repo, for the GitOps plane.

All three tokens go into Bitwarden (homelab project); the bot reads them via an
ExternalSecret. None live in Git.

## Build outline

- Small **Go** service using `slack-go` socketmode.
- Image published to GHCR.
- Deployed as a Deployment in a new `slack-ops` namespace with the scoped
  ClusterRole + ExternalSecret tokens, managed by ArgoCD like everything else.
- Alertmanager gets a webhook receiver → the bot, to turn alerts into actionable
  messages.
