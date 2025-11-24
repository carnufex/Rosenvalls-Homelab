# Longhorn Storage

This directory contains the configuration for Longhorn, a distributed block storage system for Kubernetes.

## Configuration

-   **Namespace**: `longhorn-system`
-   **Replicas**: Configured to `1` initially (since we have 1 worker node).
-   **Ingress**: Exposed at `longhorn.rosenvall.se` via Cloudflare Tunnel (managed by Cilium/Ingress).

## Usage

Longhorn provides the default `StorageClass` for the cluster.
When a PVC is created without specifying a storage class, Longhorn will provision the volume.

## Access

The Longhorn UI is available at: `https://longhorn.rosenvall.se`
