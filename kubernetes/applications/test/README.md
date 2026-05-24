# test

Static nginx hello-world site exposed publicly at `https://test.rosenvall.se`.

## Runtime

- Namespace: `test`
- Deployment: `test-nginx`
- Service: `test-nginx` on port `80`
- Route: `HTTPRoute/test-nginx` attached to `gateway/external`
- Image: `nginx:1.27.4-alpine@sha256:4ff102c5d78d254a6f0da062b3cf39eaf07f01eec0927fd21e219d0af8bc0591`

After this app is merged and synced by ArgoCD, verify the route with:

```powershell
kubectl get pods -n test
kubectl get svc -n test
kubectl get httproute -n test
curl https://test.rosenvall.se
```
