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

  nodes = var.nodes
}
