resource "proxmox_virtual_environment_vm" "this" {
  for_each = var.nodes

  name      = each.key
  node_name = each.value.host_node
  vm_id     = each.value.vm_id
  machine   = "q35"

  agent {
    enabled = true
  }

  # GPU nodes need virtio VGA instead of default
  dynamic "vga" {
    for_each = each.value.igpu ? [1] : []
    content {
      type = "virtio"
    }
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
    # The Talos EPHEMERAL volume lives on the boot disk and backs kubelet/containerd.
    # Keep this independent from the dedicated Longhorn disk mounted at /var/lib/longhorn.
    size         = each.value.boot_disk_size_gib
    file_format  = "raw"
    file_id      = proxmox_virtual_environment_download_file.this[local.node_schematic_key[each.key]].id
  }

  dynamic "disk" {
    for_each = each.value.disks
    content {
      datastore_id = each.value.datastore_id
      interface    = "${disk.value.type}${disk.value.unit_number}"
      size         = tonumber(replace(disk.value.size, "G", ""))
      file_format  = "raw"
    }
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

  # GPU configuration is handled manually in Proxmox GUI due to API permission restrictions
  # The lifecycle block ensures Tofu doesn't try to remove the manually added GPU
  lifecycle {
     ignore_changes = [
       hostpci,
       kvm_arguments,
       # Once the boot disk is created, a refreshed shared Talos image should not
       # force every VM to be replaced. Planned reprovisioning still uses -replace.
       disk[0].file_id
     ]
  }

  # PCI passthrough configuration commented out to allow manual GUI configuration
  # dynamic "hostpci" {
  #   for_each = each.value.igpu && length(each.value.gpu_devices) > 0 ? {
  #     for i, bdf in each.value.gpu_devices : i => bdf
  #   } : {}
  #   content {
  #     device = "hostpci${hostpci.key}"
  #     id     = hostpci.value
  #     pcie   = true
  #     rombar = true
  #     xvga   = tonumber(hostpci.key) == 0
  #   }
  # }
}
