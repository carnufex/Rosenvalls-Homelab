# Home Assistant

Home Assistant is treated as a special-case workload in v1.

## Runtime Contract

- The namespace is marked `pod-security.kubernetes.io/enforce=baseline` so Home Assistant can run without privileged or host-network access.
- Scheduling requires a worker labeled `homelab.rosenvall.se/lan-special=true`.
- `Service/homeassistant` exists so the app can be reached through `gateway/internal` on `https://homeassistant.rosenvall.local`.
- LAN clients should resolve `*.rosenvall.local` to `192.168.1.220` on the UDM.
- Internal HTTPS uses the cluster-local CA managed in the `gateway` namespace.
- The deployment starts at `replicas: 1` after the copied Home Assistant config has been seeded.
- Home Assistant is reachable through `Service/homeassistant` and the internal Gateway route; direct node binding is intentionally disabled. The one exception is `Service/homeassistant-lan`, a LoadBalancer IP for push-based IoT — see "Direct LAN exposure for push-based IoT" below.

## Direct LAN exposure for push-based IoT (Shelly etc.)

Some IoT devices are **push-based and cannot be polled** — a battery Shelly Plus
H&T wakes, opens an *Outbound WebSocket* to HA, pushes its reading, and sleeps.
Two properties of the default setup make the internal Gateway route unusable for
them, so they need a direct LAN endpoint:

- HA's plain HTTP port `8123` only exists as a ClusterIP / pod IP
  (`10.244.0.0/16`), which is **not reachable from the WiFi LAN**. If a device's
  WebSocket target shows a `10.244.x.x` address, that is HA's pod IP and it will
  never work off-cluster.
- The internal Gateway listens on `443` with a **cluster-local CA** cert that
  most IoT firmware cannot be made to trust, so `wss://…rosenvall.local` fails
  the TLS handshake on the device.

`Service/homeassistant-lan` (`lan-service.yaml`) solves this by pinning
**`192.168.1.224`** via Cilium LB-IPAM and serving plain `8123` straight to the
pod. Point such devices at:

```
ws://192.168.1.224:8123/api/shelly/ws
```

Requirements for the IP to actually come up on the LAN (both already done for
`homeassistant`, but needed for any future namespace that wants a LAN IP):

- The `homeassistant` namespace is listed in the `CiliumLoadBalancerIPPool`
  (`first-pool`) **and** the `CiliumL2AnnouncementPolicy`, both under
  `kubernetes/infrastructure/network/cilium/`. Missing the announcement policy
  allocates the IP but never ARPs it → silently unreachable.
- `192.168.1.224` is within `first-pool` (`.220-.229`); current map: `.220`
  internal gw, `.222` external gw, `.223` gatebound TFS, `.224` HA LAN.

This is a deliberate exception to "direct node binding is intentionally disabled"
below — it is scoped to a single extra LoadBalancer IP for LAN IoT ingress, the
Gateway remains the path for browser/OIDC traffic.

## Seeding

Seed the config PVC with:

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
.\scripts\seed-homeassistant.ps1
```

The seed script:

- copies the downloaded Home Assistant config into `PersistentVolumeClaim/homeassistant-config`
- removes `.ha_run.lock`
- forces `use_x_forwarded_for: true`
- rewrites `trusted_proxies` to the cluster network plus localhost
- sets the stored Home Assistant internal and external URL to `https://homeassistant.rosenvall.local`

## Scope

- No public `HTTPRoute` is created in v1; only the internal route is included.
- USB passthrough is intentionally out of scope for this first cut. If Home Assistant later needs direct Zigbee, Z-Wave, or Bluetooth devices, that should be handled as a separate Talos or device change.
