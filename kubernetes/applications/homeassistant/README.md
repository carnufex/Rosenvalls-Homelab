# Home Assistant

Home Assistant is treated as a special-case workload in v1.

## Runtime Contract

- The namespace is explicitly marked `pod-security.kubernetes.io/enforce=privileged` because the workload uses `hostNetwork` and a privileged container to stay close to the current Docker contract.
- Scheduling requires a worker labeled `homelab.rosenvall.se/lan-special=true`. The included Tofu changes add that label to the example `worker-01` definition.
- `Service/homeassistant` exists so the app can be reached through `gateway/internal` on `https://homeassistant.rosenvall.local`.
- LAN clients should resolve `*.rosenvall.local` to `192.168.1.220` on the UDM.
- Internal HTTPS for `*.rosenvall.local` uses the cluster-local CA managed in the `gateway` namespace.
- The deployment starts at `replicas: 0` so the copied Home Assistant config can be seeded before first boot.
- Because the pod still uses `hostNetwork`, direct node access on `worker-01:8123` remains a valid fallback while debugging discovery issues.

## Manual Seeding

Copy the existing `./homeassistant` directory into `PersistentVolumeClaim/homeassistant-config` before traffic is cut over.

## Scope

- No public `HTTPRoute` is created in v1; only the internal route is included.
- USB passthrough is intentionally out of scope for this first cut. If Home Assistant later needs direct Zigbee/Z-Wave/Bluetooth devices, that should be handled as a separate Talos/device change.
