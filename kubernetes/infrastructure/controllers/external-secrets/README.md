# External Secrets with Bitwarden

## Setup

1.  Create a Machine Account in Bitwarden.
2.  Get the `AccessToken`.
3.  Create the secret in the cluster manually (or seal it):
    ```bash
    kubectl create secret generic bitwarden-access-token \
      --from-literal=token=<YOUR_ACCESS_TOKEN> \
      --namespace external-secrets
    ```
4.  Update `cluster-secret-store.yaml` with your `organizationId` and `projectId`.

## Architecture

This setup uses the Bitwarden Secrets Manager provider for External Secrets Operator.

### Components

*   **External Secrets Operator**: The controller that manages the secrets.
*   **Bitwarden SDK Server**: A helper service that runs as a sidecar or separate service to communicate with Bitwarden. It requires HTTPS.
*   **Cert Manager**: Used to generate a self-signed certificate for the SDK Server.

### TLS Configuration

The Bitwarden SDK Server requires HTTPS. We use `cert-manager` to generate a self-signed certificate:

1.  `certs.yaml` defines a self-signed `Issuer` and a `Certificate` for the SDK server.
2.  The certificate is stored in the `bitwarden-tls-certs` secret.
3.  The SDK server mounts this secret to serve HTTPS.
4.  The `ClusterSecretStore` references the CA certificate from this secret via `caProvider` to trust the connection.

This ensures secure communication between the External Secrets Operator and the Bitwarden SDK Server without manual CA bundle management.

