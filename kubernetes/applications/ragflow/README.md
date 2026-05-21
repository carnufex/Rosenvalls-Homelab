# RAGFlow

RAGFlow is exposed on the internal gateway at `https://ragflow.rosenvall.local`.

## Authentik Status

An Authentik OAuth2/OIDC provider is declared for RAGFlow with callback:

```text
https://ragflow.rosenvall.local/v1/user/oauth/callback/oidc
```

The RAGFlow Helm chart writes `ragflow.service_conf` into a ConfigMap, so the
RAGFlow client secret must not be placed there. The app is therefore not switched
to Authentik login until its OAuth client secret can be mounted from a Kubernetes
Secret or the upstream chart supports secret-backed service config.

`REGISTER_ENABLED=0` is set to prevent new local sign-ups while this is pending.
Existing local users may still be able to sign in, so this does not yet satisfy
strict Authentik-only access.
