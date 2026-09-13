# gatebound-support

Player support for Gatebound: an ElevenLabs agent (text-first widget on
gatebound.rosenvall.se) backed by this service. Source and architecture:
<https://github.com/carnufex/gatebound-support> (`docs/SPEC.md`).

## What runs here

| Component | Purpose |
|---|---|
| `deployment/gatebound-support` | FastAPI: `/mcp` (Streamable HTTP MCP server for the agent), `/t/<token>` ticket pages (Discord OAuth → forum post), `/ticket/new` fallback form, `/webhooks/elevenlabs` post-call transcript, `/status` for the widget's degrade mode |
| `pvc/gatebound-support-data` | SQLite: drafts, tickets, transcripts |
| `httproute` | `gatebound-support.rosenvall.se` on `gateway/external` |

## Dependencies

- `gatebound-web.gatebound.svc:3000` — `/api/support/*` (shared secret
  `SUPPORT_API_TOKEN`, identity JWT `SUPPORT_IDENTITY_SECRET`). The support
  service never talks to MariaDB.
- ElevenLabs workspace (same API key as `oncall-demo`).
- Discord app + bot (all `DISCORD_*` are `unset` until created; tickets then
  land as `pending_manual` instead of forum posts).

## Secrets (Bitwarden SM, keys `GATEBOUND_SUPPORT_*`)

`SUPPORT_API_TOKEN`, `SUPPORT_IDENTITY_SECRET`, `MCP_SECRET`,
`ELEVENLABS_API_KEY`, `ELEVENLABS_AGENT_ID`, `ELEVENLABS_WEBHOOK_SECRET`,
`DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, `DISCORD_BOT_TOKEN`,
`DISCORD_GUILD_ID`, `DISCORD_FORUM_CHANNEL_ID`, `DISCORD_TAG_OPEN_ID`,
`DISCORD_STAFF_WEBHOOK_URL`. The web side gets `SUPPORT_API_TOKEN`,
`SUPPORT_IDENTITY_SECRET` and `SUPPORT_AGENT_ID` via `gatebound/web-externalsecret.yaml`.

## Deploy

Build + push from the source repo (`docker build --platform linux/amd64 -t
registry.rosenvall.se/carnufex/gatebound-support:sha-<short> .`, `docker push`),
then bump the image tag in `deployment.yaml` and push here; ArgoCD auto-syncs.
