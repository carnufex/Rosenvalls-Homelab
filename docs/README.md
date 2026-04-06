# Documentation

This directory is the operator wiki for Rosenvalls-Homelab.

Read in this order if you are new to the repo:

1. [Getting started](getting-started/README.md)
2. [Architecture](architecture/README.md)
3. [Operations](operations/README.md)
4. [Disaster recovery](disaster-recovery/README.md)
5. [Scaling](scaling/README.md)

Jump directly to a topic:

- [Getting started](getting-started/README.md)
- [Architecture](architecture/README.md)
- [Operations](operations/README.md)
- [Disaster recovery](disaster-recovery/README.md)
- [Scaling](scaling/README.md)
- [Networking](networking/README.md)
- [Storage and backups](storage-and-backups/README.md)

## Source Of Truth

- Infrastructure lives in `tofu/`
- Kubernetes manifests live in `kubernetes/`
- The live cluster syncs from `https://github.com/carnufex/Rosenvalls-Homelab.git`
- Local edits do not affect the cluster until they are pushed to `origin`
- `bootstrap.ps1` is the imperative bridge from a fresh cluster into GitOps

## Navigation Notes

- Root `README.md` is the public landing page.
- This `docs/` tree is the active operator documentation.
- Component README files under `kubernetes/` stay close to their manifests and are used as implementation notes, not as the main onboarding path.
