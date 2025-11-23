resource "proxmox_virtual_environment_vm" "this" {
  for_each = var.nodes

  name      = each.key
  node_name = each.value.host_node
  vm_id     = each.value.vm_id

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  memory {
    dedicated = each.value.ram_dedicated
  }

  disk {
    datastore_id = coalesce(each.value.datastore_id, "local-lvm")
    interface    = "scsi0"
    size         = 20
    file_format  = "raw"
    file_id      = proxmox_virtual_environment_download_file.this.id
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.cluster.gateway
      }
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26" # Linux 2.6 - 5.x Kernel
  }
}
