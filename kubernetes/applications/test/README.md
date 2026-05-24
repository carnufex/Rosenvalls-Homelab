# Test

`test` is a minimal public NGINX Hello World app.

## Runtime Contract

- Namespace: `test`
- URL: `https://test.rosenvall.se`
- Route: `HTTPRoute/test` attaches to `gateway/external`
- Service: `test-nginx` on port `80`
- Container: `nginxinc/nginx-unprivileged:1.27.4-alpine`

The static `index.html` is provided by `ConfigMap/test-nginx-content`.
