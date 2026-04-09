# Home Assistant

Home Assistant is treated as a special-case workload in v1.

## Runtime Contract

- The namespace is explicitly marked `pod-security.kubernetes.io/enforce=privileged` because the workload uses `hostNetwork` and a privileged container to stay close to the current Docker contract.
- Scheduling requires a worker labeled `homelab.rosenvall.se/lan-special=true`.
- `Service/homeassistant` exists so the app can be reached through `gateway/internal` on `https://homeassistant.rosenvall.local`.
- LAN clients should resolve `*.rosenvall.local` to `192.168.1.220` on the UDM.
- Internal HTTPS uses the cluster-local CA managed in the `gateway` namespace.
- The deployment starts at `replicas: 0` so the copied Home Assistant config can be seeded before first boot.
- Because the pod still uses `hostNetwork`, direct node access on `worker-01:8123` remains a valid fallback while debugging discovery issues.

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
