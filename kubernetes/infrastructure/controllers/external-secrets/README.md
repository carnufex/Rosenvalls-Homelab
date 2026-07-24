# External Secrets with Bitwarden

## Setup

1. Create a Machine Account in Bitwarden Secrets Manager.
2. Get the machine account access token.
3. Create the bootstrap secret in the cluster manually:

   ```powershell
   kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
   kubectl create secret generic bitwarden-access-token `
     --from-literal=token=<YOUR_ACCESS_TOKEN> `
     --namespace external-secrets `
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. Update `cluster-secret-store.yaml` with the correct `organizationID` and `projectID`.

This secret is intentionally out-of-band. If it disappears, `ClusterSecretStore/bitwarden-secretsmanager` becomes `InvalidProviderConfig`, which then breaks:

- Cloudflare tunnel token sync
- cert-manager Cloudflare API token sync
- ArgoCD and Authentik runtime secrets
- Longhorn and CloudNativePG backup credentials

Some application namespaces use dedicated `ClusterSecretStore` objects with a
single-namespace condition, such as `bitwarden-secretsmanager-matplan` and
`bitwarden-secretsmanager-rosenvall-devops`. These stores narrow where each
ExternalSecret may be used. They still depend on the manual
`bitwarden-access-token` bootstrap secret unless they are moved to a separate
Bitwarden machine account.

## Architecture

This setup uses the Bitwarden Secrets Manager provider for External Secrets Operator.

### Components

- **External Secrets Operator**: The controller that manages the secrets.
- **Bitwarden SDK Server**: A helper service that serves the Bitwarden provider over HTTPS.
- **Cert Manager**: Generates the TLS certificate for the SDK server.

### TLS Configuration

The Bitwarden SDK Server requires HTTPS. We use `cert-manager` to generate a self-signed certificate:

1. `certs.yaml` defines a self-signed `Issuer` and a `Certificate` for the SDK server.
2. The certificate is stored in the `bitwarden-tls-certs` secret.
3. The SDK server mounts this secret to serve HTTPS.
4. The `ClusterSecretStore` references the CA certificate from this secret via `caProvider`.
