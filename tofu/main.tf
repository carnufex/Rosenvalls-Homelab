locals {
  node_defaults = {
    worker       = var.defaults_worker
    controlplane = var.defaults_controlplane
  }

  nodes = {
    for name, config in var.nodes_config : name => merge(
      try(
        local.node_defaults[config.machine_type],
        error("machine_type '${config.machine_type}' has no defaults")
      ),
      { for k, v in config : k => v if v != null },
      {
        disks = {
          for disk_name, disk_defaults in try(local.node_defaults[config.machine_type].disks, {}) :
          disk_name => merge(
            disk_defaults,
            coalesce(lookup(coalesce(config.disks, {}), disk_name, null), {})
          )
        }
      },
      {
        host_node    = coalesce(config.host_node, nonsensitive(var.proxmox.name))
        datastore_id = var.proxmox_datastore
      }
    )
  }
}

module "talos" {
  source = "./talos"

  providers = {
    proxmox = proxmox
  }

  image = {
    version = var.talos_version
  }

  cluster = {
    name            = var.cluster_name
    endpoint        = var.cluster_endpoint
    talos_version   = var.talos_version
    proxmox_cluster = var.proxmox.cluster_name
    gateway         = var.gateway
  }

  cilium = {
    values  = file("${path.module}/../kubernetes/infrastructure/network/cilium/values.yaml")
    install = file("${path.module}/talos/inline-manifests/cilium-install.yaml")
  }

  nodes = local.nodes
}
