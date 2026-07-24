#!/usr/bin/env python3
"""Homelab Slack ops bot — deterministic, button-driven remediation.

Connects to Slack over Socket Mode (outbound WebSocket, no public endpoint)
using only an app-level token. Posts an action menu via the existing incoming
webhook and responds to button clicks via the interaction `response_url`, so no
bot (xoxb) token is required.

Guardrails: a fixed whitelist of actions, protected namespaces that mutations
refuse to touch, and a confirm step before anything destructive. The hard
boundary is the ServiceAccount RBAC (scoped, deny-by-omission).
"""
import json
import logging
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests
from kubernetes import client, config
from slack_sdk.socket_mode import SocketModeClient
from slack_sdk.socket_mode.request import SocketModeRequest
from slack_sdk.socket_mode.response import SocketModeResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("slack-ops-bot")

APP_TOKEN = os.environ.get("SLACK_APP_TOKEN", "")
WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")

# Mutations never touch these namespaces (databases, platform, the bot itself).
PROTECTED_NS = {
    "kube-system", "longhorn-system", "external-secrets", "cnpg-system",
    "authentik", "gateway", "cert-manager", "argocd", "matplan",
    "slack-ops-bot",
}

# The one disposable volume we know how to reset (the prometheus crashloop fix).
PROM_NS = "monitoring"
PROM_PVC = ("prometheus-kube-prometheus-stack-prometheus-db-"
            "prometheus-kube-prometheus-stack-prometheus-0")
PROM_POD = "prometheus-kube-prometheus-stack-prometheus-0"

if not APP_TOKEN.startswith("xapp-"):
    log.error("SLACK_APP_TOKEN missing or not an app-level token (xapp-...). Exiting.")
    sys.exit(1)

config.load_incluster_config()
core = client.CoreV1Api()
batch = client.BatchV1Api()
crd = client.CustomObjectsApi()

# Alerts that get a "Clean orphaned volumes" button posted with them.
ACTIONABLE_ALERTS = {"LonghornNodeStorageLow"}


# ---------------------------------------------------------------- remediations
def cluster_status():
    out = []
    nodes = core.list_node().items
    ready = sum(
        1 for n in nodes for c in (n.status.conditions or [])
        if c.type == "Ready" and c.status == "True"
    )
    out.append(f"• Nodes: {ready}/{len(nodes)} Ready")

    pods = core.list_pod_for_all_namespaces().items
    bad = []
    for p in pods:
        waiting_bad = any(
            cs.state and cs.state.waiting and cs.state.waiting.reason in
            ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull")
            for cs in (p.status.container_statuses or [])
        )
        if p.status.phase not in ("Running", "Succeeded") or waiting_bad:
            bad.append(f"{p.metadata.namespace}/{p.metadata.name}")
    out.append(f"• Pods needing attention: {len(bad)}"
               + (": " + ", ".join(bad[:8]) if bad else ""))

    jobs = batch.list_job_for_all_namespaces().items
    failed = [f"{j.metadata.namespace}/{j.metadata.name}"
              for j in jobs if (j.status.failed or 0) > 0]
    out.append(f"• Failed jobs: {len(failed)}"
               + (": " + ", ".join(failed[:8]) if failed else ""))
    return "\n".join(out)


def clean_failed_jobs():
    deleted = []
    for j in batch.list_job_for_all_namespaces().items:
        ns = j.metadata.namespace
        if ns in PROTECTED_NS:
            continue
        if (j.status.failed or 0) > 0 and (j.status.active or 0) == 0:
            try:
                batch.delete_namespaced_job(
                    j.metadata.name, ns, propagation_policy="Background")
                deleted.append(f"{ns}/{j.metadata.name}")
            except Exception as e:  # noqa: BLE001
                log.warning("delete job %s/%s failed: %s", ns, j.metadata.name, e)
    return deleted


def reset_prometheus():
    msgs = []
    try:
        core.delete_namespaced_persistent_volume_claim(PROM_PVC, PROM_NS)
        msgs.append(f"• deleted PVC {PROM_PVC}")
    except Exception as e:  # noqa: BLE001
        msgs.append(f"• PVC delete: {e}")
    try:
        core.delete_namespaced_pod(PROM_POD, PROM_NS)
        msgs.append(f"• deleted pod {PROM_POD} (StatefulSet recreates with a fresh volume)")
    except Exception as e:  # noqa: BLE001
        msgs.append(f"• pod delete: {e}")
    return msgs


def clean_orphans():
    """Delete orphaned Longhorn storage: PVs in the Released phase (no PVC bound)
    and their backing Longhorn volume. Guardrail: ONLY Released, longhorn-backed
    PVs are ever touched — a Bound (in-use) volume is never deleted."""
    freed = []
    for pv in core.list_persistent_volume().items:
        if pv.status.phase != "Released":
            continue
        if not (pv.spec.storage_class_name or "").startswith("longhorn"):
            continue
        name = pv.metadata.name
        try:  # the Longhorn volume frees the actual disk space
            crd.delete_namespaced_custom_object(
                group="longhorn.io", version="v1beta2",
                namespace="longhorn-system", plural="volumes", name=name)
        except Exception as e:  # noqa: BLE001
            log.warning("delete longhorn volume %s: %s", name, e)
        try:
            core.delete_persistent_volume(name)
        except Exception as e:  # noqa: BLE001
            log.warning("delete pv %s: %s", name, e)
        cr = pv.spec.claim_ref
        claim = f"{cr.namespace}/{cr.name}" if cr else "-"
        freed.append(f"{name[:18]}… ({claim})")
    return freed


# ------------------------------------------------------------------- block kit
def menu_blocks():
    return [
        {"type": "section", "text": {"type": "mrkdwn",
         "text": ":robot_face: *Homelab Ops Bot* — pick an action:"}},
        {"type": "actions", "elements": [
            {"type": "button", "text": {"type": "plain_text", "text": "📊 Cluster status"},
             "action_id": "status"},
            {"type": "button", "text": {"type": "plain_text", "text": "🧹 Clean failed jobs"},
             "action_id": "clean_jobs_confirm", "style": "primary"},
            {"type": "button", "text": {"type": "plain_text", "text": "🗑️ Clean orphaned volumes"},
             "action_id": "clean_orphans_confirm", "style": "primary"},
            {"type": "button", "text": {"type": "plain_text", "text": "♻️ Reset Prometheus volume"},
             "action_id": "reset_prom_confirm", "style": "danger"},
        ]},
    ]


def confirm_blocks(do_action, label, warn):
    return [
        {"type": "section", "text": {"type": "mrkdwn", "text": f":warning: *Confirm:* {warn}"}},
        {"type": "actions", "elements": [
            {"type": "button", "text": {"type": "plain_text", "text": f"Yes — {label}"},
             "action_id": do_action, "style": "danger"},
            {"type": "button", "text": {"type": "plain_text", "text": "Cancel"},
             "action_id": "cancel"},
        ]},
    ]


def section(text):
    return [{"type": "section", "text": {"type": "mrkdwn", "text": text}}]


def status_blocks():
    # Cluster status + inline remediation buttons (ChatOps from the status msg).
    return section(":bar_chart: *Cluster status*\n" + cluster_status()) + [
        {"type": "actions", "elements": [
            {"type": "button", "text": {"type": "plain_text", "text": "🧹 Clean failed jobs"},
             "action_id": "clean_jobs_confirm", "style": "primary"},
            {"type": "button", "text": {"type": "plain_text", "text": "🗑️ Clean orphaned volumes"},
             "action_id": "clean_orphans_confirm"},
            {"type": "button", "text": {"type": "plain_text", "text": "🔄 Refresh"},
             "action_id": "status"},
        ]},
    ]


def respond(response_url, blocks, text="Homelab Ops Bot"):
    # replace_original=False -> post a new message, keeping the persistent menu.
    try:
        requests.post(response_url, json={"replace_original": False, "text": text,
                                          "blocks": blocks}, timeout=10)
    except Exception as e:  # noqa: BLE001
        log.warning("respond failed: %s", e)


def post_webhook(blocks, text):
    if not WEBHOOK_URL:
        log.warning("no webhook url; cannot post menu")
        return
    try:
        r = requests.post(WEBHOOK_URL, json={"text": text, "blocks": blocks}, timeout=10)
        log.info("posted via webhook: %s", r.status_code)
    except Exception as e:  # noqa: BLE001
        log.warning("webhook post failed: %s", e)


def post_actionable_alert(alert):
    """Re-post a firing alert to Slack with a remediation button."""
    labels = alert.get("labels", {})
    ann = alert.get("annotations", {})
    name = labels.get("alertname", "alert")
    summary = ann.get("summary", name)
    desc = ann.get("description", "")
    blocks = [
        {"type": "section", "text": {"type": "mrkdwn",
         "text": f":warning: *{name}*\n{summary}\n{desc}"}},
        {"type": "actions", "elements": [
            {"type": "button", "text": {"type": "plain_text", "text": "🗑️ Clean orphaned volumes"},
             "action_id": "clean_orphans_confirm", "style": "primary"},
            {"type": "button", "text": {"type": "plain_text", "text": "📊 Cluster status"},
             "action_id": "status"},
        ]},
    ]
    post_webhook(blocks, summary)


# Alertmanager posts firing alerts here (in-cluster ClusterIP, no public ingress).
# Matching alerts get re-posted to Slack with an action button.
class AlertReceiver(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        self.send_response(200)
        self.end_headers()
        try:
            data = json.loads(raw)
        except Exception:  # noqa: BLE001
            return
        for a in data.get("alerts", []):
            if a.get("status") == "firing" and \
                    a.get("labels", {}).get("alertname") in ACTIONABLE_ALERTS:
                try:
                    post_actionable_alert(a)
                except Exception:  # noqa: BLE001
                    log.exception("post_actionable_alert failed")

    def log_message(self, *a):  # silence default request logging
        pass


def start_alert_http():
    HTTPServer(("0.0.0.0", 8080), AlertReceiver).serve_forever()


# --------------------------------------------------------------------- actions
def handle_action(action, response_url, user):
    if action == "status":
        respond(response_url, status_blocks())
    elif action == "clean_jobs_confirm":
        respond(response_url, confirm_blocks(
            "clean_jobs_do", "clean failed jobs",
            "Delete all finished *failed* Jobs outside protected namespaces?"))
    elif action == "clean_jobs_do":
        deleted = clean_failed_jobs()
        body = (f":white_check_mark: Deleted {len(deleted)} failed job(s)"
                + (": " + ", ".join(deleted) if deleted else " (none found)")
                + f"\n_by {user}_")
        respond(response_url, section(body))
    elif action == "reset_prom_confirm":
        respond(response_url, confirm_blocks(
            "reset_prom_do", "reset Prometheus",
            "Delete the Prometheus PVC + pod so it recreates a fresh volume? "
            "Historical metrics will be lost."))
    elif action == "reset_prom_do":
        msgs = reset_prometheus()
        respond(response_url, section(":white_check_mark: *Prometheus reset triggered*\n"
                                      + "\n".join(msgs) + f"\n_by {user}_"))
    elif action == "clean_orphans_confirm":
        respond(response_url, confirm_blocks(
            "clean_orphans_do", "clean orphaned volumes",
            "Delete all *Released* (orphaned) Longhorn PVs + their volumes? "
            "Only unbound volumes are touched — nothing in use."))
    elif action == "clean_orphans_do":
        freed = clean_orphans()
        body = (f":white_check_mark: Cleaned {len(freed)} orphaned volume(s)"
                + ("\n• " + "\n• ".join(freed) if freed else " (none found)")
                + f"\n_by {user}_")
        respond(response_url, section(body))
    elif action == "cancel":
        respond(response_url, section("Cancelled. :wave:"))
    else:
        log.info("unknown action: %s", action)


# ----------------------------------------------------------------- socket mode
def main():
    sm = SocketModeClient(app_token=APP_TOKEN)

    def listener(c, req: SocketModeRequest):
        # Always ack first.
        c.send_socket_mode_response(SocketModeResponse(envelope_id=req.envelope_id))
        if req.type == "interactive":
            p = req.payload
            if p.get("type") == "block_actions":
                action = p["actions"][0]["action_id"]
                ru = p.get("response_url", "")
                user = "<@%s>" % p.get("user", {}).get("id", "?")
                log.info("action=%s user=%s", action, user)
                try:
                    handle_action(action, ru, user)
                except Exception as e:  # noqa: BLE001
                    log.exception("action error")
                    if ru:
                        respond(ru, section(f":x: Error running `{action}`: {e}"))

    sm.socket_mode_request_listeners.append(listener)
    sm.connect()

    connected = False
    for _ in range(15):
        if sm.is_connected():
            connected = True
            break
        time.sleep(1)
    log.info("Slack Socket Mode connected=%s — bot is live", connected)

    threading.Thread(target=start_alert_http, daemon=True).start()
    log.info("Alertmanager receiver listening on :8080")

    post_webhook(menu_blocks(), "Homelab Ops Bot online")
    threading.Event().wait()


if __name__ == "__main__":
    main()
