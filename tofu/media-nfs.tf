locals {
  media_nfs_enabled = var.media_nfs != null

  media_nfs_boot_datastore = local.media_nfs_enabled ? coalesce(try(var.media_nfs.boot_datastore, null), var.proxmox_datastore) : null
  media_nfs_image_datastore = local.media_nfs_enabled ? coalesce(try(var.media_nfs.image_datastore, null), "local") : null
  media_nfs_gateway = local.media_nfs_enabled ? coalesce(try(var.media_nfs.gateway, null), var.gateway) : null
  media_nfs_allowed_clients = local.media_nfs_enabled ? coalescelist(
    try(var.media_nfs.allowed_clients, null),
    [
      for _, node in var.nodes_config :
      "${node.ip}(rw,sync,no_subtree_check)"
      if node.machine_type == "worker"
    ]
  ) : []
  media_nfs_ssh_public_keys = compact([
    try(trimspace(file(pathexpand("~/.ssh/id_ed25519.pub"))), ""),
    try(trimspace(file(pathexpand("~/.ssh/id_rsa.pub"))), "")
  ])
}

resource "proxmox_virtual_environment_download_file" "media_nfs_debian_cloud_image" {
  count        = local.media_nfs_enabled ? 1 : 0
  content_type = "iso"
  datastore_id = local.media_nfs_image_datastore
  node_name    = var.media_nfs.host_node

  url       = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  file_name = "debian-12-genericcloud-amd64.qcow2.img"
}

resource "proxmox_virtual_environment_file" "media_nfs_user_data" {
  count        = local.media_nfs_enabled ? 1 : 0
  content_type = "snippets"
  datastore_id = local.media_nfs_image_datastore
  node_name    = var.media_nfs.host_node

  source_raw {
    file_name = "media-nfs-01-user-data.yaml"
    data = templatefile("${path.module}/templates/media-nfs-user-data.yaml.tftpl", {
      hostname            = var.media_nfs.name
      ssh_authorized_keys = local.media_nfs_ssh_public_keys
      export_path         = "/srv/nfs/media"
      allowed_clients     = join(" ", local.media_nfs_allowed_clients)
    })
  }
}

resource "proxmox_virtual_environment_vm" "media_nfs" {
  count     = local.media_nfs_enabled ? 1 : 0
  name      = var.media_nfs.name
  node_name = var.media_nfs.host_node
  vm_id     = var.media_nfs.vm_id
  machine   = "q35"
  on_boot   = true
  started   = true

  agent {
    enabled = true
  }

  cpu {
    cores = var.media_nfs.cpu
    type  = "host"
  }

  memory {
    dedicated = var.media_nfs.ram_dedicated
  }

  disk {
    datastore_id = local.media_nfs_boot_datastore
    interface    = "scsi0"
    file_id      = proxmox_virtual_environment_download_file.media_nfs_debian_cloud_image[0].id
    file_format  = "qcow2"
    discard      = "on"
    iothread     = true
    size         = var.media_nfs.boot_disk_size_gib
  }

  disk {
    datastore_id = var.media_nfs.data_datastore
    interface    = "scsi1"
    file_format  = "raw"
    discard      = "on"
    iothread     = true
    size         = var.media_nfs.data_disk_size_gib
  }

  initialization {
    datastore_id      = local.media_nfs_boot_datastore
    type              = "nocloud"
    user_data_file_id = proxmox_virtual_environment_file.media_nfs_user_data[0].id

    dns {
      domain  = "rosenvall.local"
      servers = [local.media_nfs_gateway]
    }

    ip_config {
      ipv4 {
        address = "${var.media_nfs.ip}/24"
        gateway = local.media_nfs_gateway
      }
    }
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }
}
