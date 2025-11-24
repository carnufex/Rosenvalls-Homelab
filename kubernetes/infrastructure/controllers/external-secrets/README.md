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
