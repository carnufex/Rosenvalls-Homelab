locals {
  nfs_servers = var.nfs_server.enabled ? { nfs = var.nfs_server } : {}
}

resource "proxmox_virtual_environment_download_file" "nfs_debian" {
  for_each = local.nfs_servers

  content_type = "iso"
  datastore_id = "local"
  node_name    = each.value.host_node

  # Debian Bookworm build 20260722-2547, pinned to its official SHA512SUMS.
  url                = "https://cloud.debian.org/images/cloud/bookworm/20260722-2547/debian-12-generic-amd64-20260722-2547.qcow2"
  file_name          = "debian-12-generic-amd64-20260722-2547.qcow2.img"
  checksum           = "5f4f2e1a242447a5e5c48cdc7c6bdfe7b44ffd1a58836ddea8cf6140a65dd702d9d67462cd6941dfd5f0efd0be1db840c2a6ffa82c24b913878be4c8ee7a6eee"
  checksum_algorithm = "sha512"
}

resource "proxmox_virtual_environment_vm" "nfs" {
  for_each = local.nfs_servers

  name          = each.value.name
  node_name     = each.value.host_node
  vm_id         = each.value.vm_id
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]
  on_boot       = true
  started       = true
  protection    = true
  tags          = ["nfs", "storage", "wd-red"]

  agent {
    # Keep false until Task 4 guest bootstrap starts qemu-guest-agent, then
    # flip agent_enabled to true in the local terraform.tfvars.
    enabled = each.value.agent_enabled
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = each.value.boot_datastore
    interface    = "scsi0"
    size         = 32
    file_format  = "raw"
    file_id      = proxmox_virtual_environment_download_file.nfs_debian[each.key].id
    discard      = "on"
    iothread     = true
  }

  disk {
    datastore_id = each.value.data_datastore
    interface    = "scsi1"
    size         = each.value.data_disk_size_gib
    file_format  = "raw"
    serial       = "NFS01DATA"
    backup       = false
    iothread     = true
  }

  initialization {
    datastore_id = each.value.boot_datastore

    dns {
      domain  = "rosenvall.local"
      servers = [each.value.gateway]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = each.value.gateway
      }
    }

    user_account {
      username = "debian"
      keys     = each.value.ssh_public_keys
    }
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  lifecycle {
    # The data disk is intended to hold persistent NFS data and must never be
    # removed by a normal OpenTofu operation.
    prevent_destroy = true

    # Updating the source image should not replace the installed boot disk.
    ignore_changes = [disk[0].file_id]
  }
}
