variable "image" {
  description = "Talos image configuration"
  type = object({
    factory_url       = optional(string, "https://factory.talos.dev")
    version           = string
    arch              = optional(string, "amd64")
    platform          = optional(string, "nocloud")
    proxmox_datastore = optional(string, "local")
  })
}

variable "cluster" {
  description = "Cluster configuration"
  type = object({
    name            = string
    endpoint        = string
    talos_version   = string
    proxmox_cluster = string
    gateway         = string
  })
}

variable "nodes" {
  description = "Configuration for cluster nodes"
  type = map(object({
    host_node                    = string
    machine_type                 = string
    boot_disk_size_gib           = number
    datastore_id                 = optional(string)
    ip                           = string
    mac_address                  = optional(string)
    vm_id                        = optional(number)
    cpu                          = number
    ram_dedicated                = number
    igpu                         = optional(bool, false)
    gpu_node_exclusive           = optional(bool, true)
    gpu_devices                  = optional(list(string), [])
    longhorn_create_default_disk = optional(bool, true)
    extra_labels                 = optional(map(string), {})
    gpu_device_meta = optional(map(object({
      id           = string
      subsystem_id = string
      iommu_group  = number
    })), {})
    disks = optional(map(object({
      device      = string
      size        = string
      type        = string
      mountpoint  = string
      unit_number = number
    })), {})
  }))
}

variable "cilium" {
  description = "Cilium configuration"
  type = object({
    values  = string
    install = string
  })
}
