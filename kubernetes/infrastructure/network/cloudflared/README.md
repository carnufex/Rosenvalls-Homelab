# Cloudflared Setup

This directory contains the configuration for the Cloudflare Tunnel.

## Prerequisites

1.  A Cloudflare account.
2.  A domain managed by Cloudflare.

## Setup Instructions

1.  **Create a Tunnel**:
    Go to the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/).
    Navigate to **Networks** > **Tunnels**.
    Create a new tunnel (select "Cloudflared" as the connector).
    Name it (e.g., `homelab`).

2.  **Get the Token**:
    After creating the tunnel, you will see a command to install the connector.
    Copy the token from that command. It looks like a long base64 string following `--token`.

3.  **Store Token in Bitwarden**:
    Create a new item in your Bitwarden project.
    Add a hidden field named `TUNNEL_TOKEN` with the token value.
    Copy the Item UUID.

4.  **Configure External Secret**:
    Update `external-secret.yaml` with the Item UUID in the `remoteRef.key` field.


3.  **Create the Secret**:
    Run the following command in your terminal (replace `<YOUR_TOKEN>` with the actual token):

    ```powershell
    kubectl create namespace cloudflare --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n cloudflare create secret generic cloudflared-secret --from-literal=TUNNEL_TOKEN=<YOUR_TOKEN>
    ```

4.  **Configure Ingress**:
    In the Cloudflare Dashboard, configure the "Public Hostname" for the tunnel.
    - **Service**: `http://traefik.kube-system.svc.cluster.local:80` (or whatever ingress controller you use).
    
    *Note: Since we are using Cilium, we might not have an Ingress Controller set up yet unless we enabled Cilium Ingress or installed Traefik/Nginx. If using Cilium Ingress, point it to the Cilium Ingress service.*

    If you just want to expose ArgoCD directly for now:
    - **Hostname**: `argocd.yourdomain.com`
    - **Service**: `https://argocd-server.argocd.svc.cluster.local:443`
    - **Additional Settings**: Enable "No TLS Verify" (since ArgoCD uses self-signed certs).

## Deployment

The `cloudflared` deployment in this directory will automatically connect using the token provided in the secret.
