variable "defaults_worker" {
  description = "Default configuration for worker nodes"
  type = object({
    host_node          = optional(string)
    machine_type       = string
    boot_disk_size_gib = number
    cpu                = number
    cpu_units          = optional(number)
    ram_dedicated      = number
    igpu               = bool
    gpu_node_exclusive = bool
    gpu_devices        = list(string)
    gpu_device_meta = map(object({
      id           = string
      subsystem_id = string
      iommu_group  = number
    }))
    extra_labels = map(string)
    disks = map(object({
      device      = string
      size        = string
      type        = string
      mountpoint  = string
      unit_number = number
    }))
  })
  default = {
    machine_type       = "worker"
    boot_disk_size_gib = 64
    cpu                = 4
    cpu_units          = 1024
    ram_dedicated      = 8192
    igpu               = false
    gpu_node_exclusive = false
    gpu_devices        = []
    gpu_device_meta    = {}
    extra_labels       = {}
    disks = {
      longhorn = {
        device      = "/dev/sdb"
        size        = "100G"
        type        = "scsi"
        mountpoint  = "/var/lib/longhorn"
        unit_number = 1
      }
    }
  }
}

variable "defaults_controlplane" {
  description = "Default configuration for control plane nodes"
  type = object({
    host_node          = optional(string)
    machine_type       = string
    boot_disk_size_gib = number
    cpu                = number
    cpu_units          = optional(number)
    ram_dedicated      = number
    igpu               = bool
    gpu_node_exclusive = bool
    gpu_devices        = list(string)
    gpu_device_meta = map(object({
      id           = string
      subsystem_id = string
      iommu_group  = number
    }))
    extra_labels = map(string)
    disks = map(object({
      device      = string
      size        = string
      type        = string
      mountpoint  = string
      unit_number = number
    }))
  })
  default = {
    machine_type       = "controlplane"
    boot_disk_size_gib = 64
    cpu                = 2
    cpu_units          = 1024
    ram_dedicated      = 4096
    igpu               = false
    gpu_node_exclusive = false
    gpu_devices        = []
    gpu_device_meta    = {}
    extra_labels       = {}
    disks              = {}
  }
}
