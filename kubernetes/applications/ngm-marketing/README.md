# NGM marketing site

Statisk landningssida för Next Generation Me. Källa: `carnufex/NextGenerationMe`
under `marketing/` (ren HTML/CSS, `nginxinc/nginx-unprivileged:alpine`).

**Live:** https://ngm.rosenvall.se (via wildcard-tunneln, ingen extra DNS behövs).

## Deploy

```
cd NextGenerationMe/marketing
docker build --platform linux/amd64 -t registry.rosenvall.se/carnufex/ngm-marketing:latest -t registry.rosenvall.se/carnufex/ngm-marketing:sha-<git-short> .
docker push registry.rosenvall.se/carnufex/ngm-marketing --all-tags
```

Bumpa sha-taggen i `deployment.yaml` — ArgoCD synkar.

## Att aktivera nextgenerationme.com (manuella Cloudflare-steg)

Tunneln och gatewayn hanterar i dag bara `*.rosenvall.se`. För .com-domänen:

1. **Cloudflare:** lägg zonen `nextgenerationme.com` i kontot (om den inte redan finns)
   och peka registrarens namnservrar dit.
2. **DNS:** CNAME `nextgenerationme.com` och `www` → tunnelns `<tunnel-id>.cfargotunnel.com`
   (proxied). Edge-certet utfärdas automatiskt när zonen är aktiv.
3. **Tunnel:** lägg till public hostname-routes för `nextgenerationme.com` + `www` med
   samma origin som wildcard-routen
   (`https://cilium-gateway-external.gateway.svc.cluster.local:443`,
   `Match SNI to Host` PÅ, `No TLS Verify` PÅ) — se
   `../../infrastructure/network/cloudflared/README.md`.
4. **Gateway:** lägg en HTTPS-listener för `nextgenerationme.com` i
   `../../infrastructure/network/gateway/gw-external.yaml` med ett cert
   (t.ex. nytt Certificate + samma DNS01-issuer om Cloudflare-tokenen får
   behörighet till .com-zonen; annars räcker ett self-signed via local-issuern
   eftersom cloudflared kör `noTLSVerify`).
5. Avkommentera hostnamnen i `httproute.yaml` här.
