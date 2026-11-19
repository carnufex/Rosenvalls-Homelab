# Kluster-inventering 2026-11-19

Skrivskyddad kartläggning inför "skala ner gammalt skräp". Inget är ändrat i klustret eller repot.
Källor: `kubectl get` (pods, workloads, PVC, Longhorn volumes/nodes), `kubectl top` (metrics-server, ögonblicksbild
2026-11-19 under pågående Talos-uppgradering), Prometheus (3 dygn), update-centers `update-center-usage-history`
(30 dygn, medel/peak per container).

## Klustertotaler

| | Allokerbart | Requestat | Använt nu (`top nodes`) |
|---|---|---|---|
| CPU (12 noder) | 36,4 kärnor | 11,7 kärnor (32 %) | 3,7 kärnor (10 %) |
| Minne (12 noder) | 74,8 GiB | 24,5 GiB (34 %) | 35,9 GiB (49 %) |

* Minnet är det som tar slut, inte CPU: *använt* (49 %) ligger långt över *requestat* (34 %) — många pods saknar
  requests (promtail ×12 ≈ 1,0 GiB, node-exporter, cert-manager, external-secrets, cnpg-system, demo-appar).
* CPU: Longhorn ensamt requestar 6,07 kärnor (52 % av klustrets alla CPU-requests) men använder ~0,47.
* worker-05 är cordonad (pågående uppgradering) — alla siffror är en ögonblicksbild.

Noder (allokerbart minne): control-01..03 5,2 GiB var · worker-01 7,3 · -02 7,3 · -03 5,3 · -04 11,2 · -05 5,3 ·
-06 3,3 · -07 5,3 · -08 5,3 · -09 7,3.

### Longhorn per disknod (GiB)

| Nod | Disk (max) | Schemalagt | Tillgängligt | Kommentar |
|---|---|---|---|---|
| worker-01 | 99,9 | 69,8 | 50,9 | |
| worker-02 | 99,9 | 41,3 | 84,9 | gott om plats |
| worker-03 | 99,9 | **154,0** | 62,1 | överbokad 154 % |
| worker-04 | 29,9 | 0,0 | 29,2 | tom, men liten |
| worker-07 | 79,9 | **179,0** | **29,5** | mest överbokad (224 %), minst ledigt |
| **Summa** | 409,6 | 444,0 | 256,6 | |

**Viktigt:** att skala en app till 0 ger tillbaka minne/CPU men **inte** Longhorn-utrymme — PVC:erna ligger kvar och
schemalagd storlek räknas ändå. Utrymme frigörs bara av att minska/ta bort PVC:er (se "Storage-observationer").

## Tabellen — sorterad på minnes-request, därefter Longhorn-storlek

Förklaring: **Mem req** = summa container-requests (MiB). **Mem nu** = `kubectl top` (MiB). **CPU 3d** = snittanvändning
sista 3 dygnen (Prometheus, mCPU). **LH** = schemalagt (PVC × repliker) / faktiskt på disk (alla repliker), GiB.
**Nät rx** = inkommande nätverk 3-dygnssnitt (proxy för trafik; Cilium-gatewayn exponerar ingen per-route-metrik).
Core = skala aldrig ner.

| Namnrymd / app | Workloads (repl.) | Mem req (lim) | Mem nu | CPU req → nu (3d snitt) | LH sched / disk | Aktivitet | Verdikt |
|---|---|---|---|---|---|---|---|
| **authentik** | server 1, worker 1, CNPG pg 1; cron db-dump | 7 680 (10 240) | 1 349 | 800 m → 103 m (103 m) | 80 / 3,8 | authentik.rosenvall.se/.local, SSO för alla appar, 0 restarter, nät 18 KB/s | **Core.** Men `authentik-worker` requestar **6 144 MiB** och använder ~440 (30d-snitt 409): sänk request → ~5,5 GiB frigörs utan att något stängs av. PVC:er 90 GiB (pg 20+20 ×2, db-dumps 50 NFS) vs 3,8 GiB använt |
| **kube-system** (cilium, envoy, coredns, talos m.m.) | 40 pods | 2 700 | 10 293 | 1 005 m → 728 m | – | – | **Core** |
| **longhorn-system** | 50 pods, 136 restarter (uppgradering) | 2 688 | 4 435 | 6 066 m → 466 m | – | – | **Core.** CPU-requests 13× över användning — kandidat för request-trim, inte nedskalning |
| **monitoring** | prometheus, alertmanager, grafana, loki, promtail ×12, node-exporter ×12, kube-state-metrics, operator, **tempo**, **otel-collector**; 5 cron | 2 248 (4 992) | 3 985 | 1 000 m → 309 m (249 m) | 80 / 43,4 | Prometheus 40 GiB använt av 50. Grafana/Prometheus internal-route. 0 nät-trafik utöver scrape | **Core.** Delkandidater: `tempo` (256 MiB req, 10 GiB PVC) + `otel-collector` (128 MiB) skapade 2026-11-14, 6 dygns historik, 184+40 MiB — skala bara ner om tracing inte används. Promtail ×12 använder ~1,0 GiB helt utan requests |
| **media** | plex, radarr, sonarr, jackett, deluge-vpn, seerr, seerr-oauth2-proxy; cron plex-self-heal (5 min), deluge-leak-check (15 min) | 1 792 (5 760) | 1 273 | 600 m → 46 m (73 m) | 64 / 17,7 (+ 3,5 TiB NFS media-library) | plex.rosenvall.se + .local, seerr.rosenvall.se; nät 705 KB/s (högst av apparna); plex CPU-snitt 231 m, deluge 186 m (30d) | **Aktivt.** Inom stacken: `jackett` (128 req, 217 nu, CPU ~13 m) och `seerr`+proxy (320 req, kan vara oanvänd om ingen ber om filmer) är det man i så fall minskar |
| **immich** | server, machine-learning, postgresql, valkey; cron onedrive-backup | 1 344 (5 376) | 1 430 | 625 m → 112 m (109 m) | 20 / 2,9 (+ 2 TiB NFS) | immich.rosenvall.se, CPU-snitt 293 m/30d, nyss migrerad till PG17 | **Aktivt** (foto-backup). `machine-learning` (512 MiB req, 202 nu) är det enda som kan stängas om smart-sök/ansikten inte behövs |
| **rosenvall-devops** (RDO) | api, forgejo, frontend; 2 cron (varje timme) | 1 344 (4 224) | 354 | 225 m → 5 m (1,5 m) | 13 / 0,7 | devops.rosenvall.se, nät 0,26 KB/s, API-pod startad idag (deploy). `api` requestar 1 024 MiB men använder ~260 | **Kandidat** om projektet vilar; annars sänk `api`-request (~750 MiB). Hör ihop med demo-appar nedan |
| **cmdb** | api, web, CNPG pg 1; cron db-dump | 1 312 (4 224) | 1 418 | 210 m → 12 m (56 m) | 28 / 24,4 | cmdb.rosenvall.se, nät 17 KB/s, aktivt utvecklad (deploy idag), PG-disk 8,9+3,3 GiB | **Behåll** (eget aktivt projekt). Dyrast i Longhorn-disk av apparna |
| **ngm** (`träna.rosenvall.se`) | ngm, CNPG pg ×2; cron db-backup + polar-sync | 672 (1 536) | 256 | 250 m → 10 m (12 m) | 18 / 1,5 | Cron-jobben går dagligen, nät 6 KB/s | **Behåll**; 2 CNPG-instanser kan bli 1 om redundans inte behövs (−256 MiB, −7 GiB sched) |
| **update-center** | server, oauth2-proxy | 576 (1 280) | 447 | 75 m → 592 m (12 m) | – | updates.rosenvall.local | **Core** |
| **lots** | lots, toolpack, CNPG pg 1; cron db-dump | 544 (1 792) | 562 | 120 m → 27 m (27 m) | 26 / 3,4 | lots.rosenvall.se, CI-mål för ARC, deploy 2026-11-18 | **Behåll** (aktivt) |
| **argocd** | 7 pods | 512 (1 024) | 841 | 100 m → 32 m | – | – | **Core** |
| **registry** | registry; 2 cron | 256 (512) | 18 | 100 m → 1 m | 100 / 42,2 (21 GiB ×2) | Pushad 2026-11-16 | **Core.** Största Longhorn-posten |
| **gatebound-support** | support, voicebot | 256 (1 024) | 147 | 100 m → 3 m (1,2 m) | 0,5 / 0,1 | gatebound-support.rosenvall.se, nät 0,11 KB/s, voicebot 3 restarter | **Kandidat** — support-agent för ett spel som är pausat sedan 2026-11-19 |
| **oncall-demo** | demo-api (2 rs), oncall-tools, oauth2-proxy | 256 (1 024) | 87 | 95 m → 6 m (2,5 m) | 0,5 / 0,1 | oncall.rosenvall.se. **Ny `demo-api`-pod CrashLoopBackOff, 202 restarter på 17 h** (den gamla replicasetet kör) | **Kandidat #1** — README: "Nothing here is part of daily operation; it can be deleted" |
| **portfolio** | portfolio ×2 | 256 (768) | 161 | 100 m → 2 m (1 m) | – | portfolio.rosenvall.se, nät 0,2 KB/s | **Kandidat**: 2 → 1 replika (−128 MiB), eller 0 tills nya CV-sidan är klar |
| **cloudflare** (cloudflared ×2) | 2 | 128 (256) | 34 | 20 m → 5 m | – | all publik trafik går här | **Core** |
| **headlamp** | 1 | 128 (512) | 17 | 50 m → 1 m (0,2 m) | – | headlamp.rosenvall.se/.local, nät 0,1 KB/s | **Kandidat** (K8s-UI, ~0 användning) |
| **slack-ops-bot** | 1 | 128 (256) | 78 | 25 m → 1 m | – | ChatOps till #homelab-alerts | Behåll (alerting-kedjan) |
| **kingsguard** | 1 | 96 (384) | 49 | 50 m → 1 m (0,1 m) | 2 / 0,1 | kingsguard.rosenvall.se, ~0 trafik | **Kandidat** (hobbyspel, 1 GiB PVC) |
| **mypassion** | app + oauth2-proxy | 96 (384) | 17 | 35 m → 2 m (0,1 m) | – | mypassion.rosenvall.se, skapad 2026-11-12, proxy 4 restarter | Ny — talet hålls nov 2026; avgör efter det |
| **arc-systems** | controller + listener | 64 (256) | 73 | 20 m → 2 m | – | CI-runner för Lots | Behåll (CI-kedjan) |
| **hub-central** | 1 | 64 (256) | 4 | 25 m → 1 m (0,01 m) | – | `rosenvall.local` (apex, internal), nät ~0 | **Kandidat** (4 MiB, praktiskt taget ingen aktivitet) |
| **cert-manager** | 3 | 0 | 158 | – | – | – | **Core** |
| **external-secrets** | 4 | 0 | 427 | – | – | – | **Core** |
| **cnpg-system** | 3 | 0 | 138 | – | – | – | **Core** (alla Postgres) |
| **devops-app-demo-klocka** | demo-klocka (inga requests) | 0 | 71 | – | – | demo-klocka.rosenvall.se, nät 0, skapad 2026-05-28, ns märkt `rosenvall-devops-board-app`, ligger **inte** i `kubernetes/applications/` | **Kandidat** (RDO-demo från maj) |
| **devops-app-demo-local-git** | demo-local-git (inga requests) | 0 | 118 | – | – | demo-local-git.rosenvall.se, nät 0, skapad 2026-05-29, samma ursprung | **Kandidat** (RDO-demo från maj) |
| **gatebound** (pausad 2026-11-19) | mariadb, tfs, web = 0 repl. | 0 | 0 | – | **14 / 1,9** (mariadb 5 + play 1 + sprites 1, ×2) | gatebound-web-route kvar; tfs låg på ~2,4 GiB/61 m i 30 d innan pausen | Redan nedskalad — kvarvarande 14 GiB Longhorn-schema |
| **ollama** | inga pods; bara ns + Service/Endpoints (externt) | 0 | 0 | – | – | Ns 266 dygn gammalt | Inget körs — kan tas bort helt (gitops-städning) |

## Slutsatser

**Core (rör inte):** argocd, kube-system (cilium), longhorn-system, cert-manager, external-secrets, cnpg-system,
authentik, monitoring (prometheus/alertmanager/grafana/loki), registry, cloudflared, update-center, slack-ops-bot, arc-systems.

**Största vinsten utan funktionsförlust:** sänk `authentik-worker` request 6 144 → ~1 024 MiB (**−5,1 GiB** request;
använder 440 MiB, 30d-snitt 409). Det är mer än alla kandidater nedan tillsammans.

**Kandidater att skala till 0, i prioritetsordning** (mem req som frigörs / verkligt minne nu):

| # | App | Frigör (request) | Verkligt nu | Skäl |
|---|---|---|---|---|
| 1 | oncall-demo | 256 MiB | 87 MiB | Sandbox som README säger kan raderas; CrashLoop 202× |
| 2 | devops-app-demo-klocka + -local-git | 0 (saknar requests) | 189 MiB | Maj-demos, noll trafik, ej i GitOps |
| 3 | rosenvall-devops (om projektet vilar) | 1 344 MiB | 354 MiB | 1,5 mCPU, ingen trafik |
| 4 | gatebound-support | 256 MiB | 147 MiB | Spelet pausat |
| 5 | portfolio (→1 replika/0), headlamp, hub-central, kingsguard | 256 + 128 + 64 + 96 = 544 MiB | ~290 MiB | ~0 trafik/CPU |
| 6 | monitoring: tempo + otel-collector | 384 MiB | ~225 MiB | Nya 11-14, om tracing inte används |
| 7 | media: seerr(+proxy), jackett | 448 MiB | ~530 MiB | Om de inte används |
| 8 | immich-machine-learning | 512 MiB | 202 MiB | Bara om smart-sök/ansikten kan vara av |

Summa 1–6 ≈ **2,9 GiB request** (varav RDO 1,3) — eller ~1,6 GiB utan RDO. Faktiskt använt minne som släpps är mindre
(~1,3 GiB / ~0,9 GiB) eftersom flera av dem överrequestar.

## Storage-observationer (Longhorn, där trycket faktiskt finns)

* Nedskalning rör inte Longhorn. Stora poster (schemalagt GiB): registry 100 (21 GiB använt ×2), authentik 80
  (3,8 använt — PVC:er 20+20 GiB × 2 repliker), monitoring 80 (Prometheus 50 GiB ×1 = 40 använt), media 64 (17,7),
  cmdb 28 (24,4 — den enda som verkligen fyller sin disk), lots 26, immich 20, ngm 18, gatebound 14, devops 13.
* Överbokningen sitter på worker-03 (154/100) och worker-07 (179/80); worker-04 (30 GiB) och worker-02 (85 GiB ledigt)
  har utrymme. Att krympa authentiks PVC:er (20+20 GiB för 1,9 GiB data, 2 repliker) är den största enskilda
  Longhorn-vinsten (~76 GiB schemalagt).
* NFS (ej Longhorn): media-library 3,5 TiB, immich-library 2 TiB, db-dumps 3 × 50 GiB.

## Vad jag inte kunde mäta

* Verklig HTTP-trafik per host: Cilium-gatewayn exponerar ingen per-route-metrik i Prometheus (inga `envoy_cluster_*`/
  `hubble_http*`-serier). "Aktivitet" bygger på pod-nätverk, CPU, restarter och deploy-datum. Cloudflare-analytics
  vore nästa steg för att se riktig publik trafik per `*.rosenvall.se`.
* `kubectl top` är en ögonblicksbild under en rullande uppgradering; 30-dygnssiffrorna (update-center) är stabilare.
