variable "proxmox" {
  type = object({
    name         = string
    cluster_name = string
    endpoint     = string
    insecure     = bool
    username     = string
    api_token    = string
  })
  sensitive = true
}
variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "talos-cluster"
}
variable "cluster_endpoint" {
  description = "Endpoint for the Kubernetes API"
  type        = string
  default     = "192.168.1.200" # VIP
}

variable "talos_version" {
  description = "Talos version to use"
  type        = string
  default     = "v1.12.11"
}

variable "gateway" {
  description = "Network gateway"
  type        = string
  default     = "192.168.1.1"
}

variable "proxmox_datastore" {
  description = "Proxmox datastore to use for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "nfs_server" {
  description = "Configuration for the dedicated WD Red-backed NFS server"
  type = object({
    enabled            = bool
    host_node          = string
    vm_id              = number
    name               = string
    ip                 = string
    gateway            = string
    boot_datastore     = string
    data_datastore     = string
    data_disk_size_gib = number
    agent_enabled      = bool
    ssh_public_keys    = list(string)
  })
  default = {
    enabled            = false
    host_node          = "desktop"
    vm_id              = 8011
    name               = "nfs-01"
    ip                 = "192.168.1.231"
    gateway            = "192.168.1.1"
    boot_datastore     = "local-lvm"
    data_datastore     = "WD-red"
    data_disk_size_gib = 2048
    agent_enabled      = false
    ssh_public_keys    = []
  }

  validation {
    condition     = !var.nfs_server.enabled || var.nfs_server.data_disk_size_gib == 2048
    error_message = "An enabled NFS server requires a 2048 GiB data disk."
  }

  validation {
    condition = !var.nfs_server.enabled || (
      length(var.nfs_server.ssh_public_keys) >= 1 &&
      alltrue([
        for key in var.nfs_server.ssh_public_keys :
        key == trimspace(key) &&
        length(key) > 0 &&
        anytrue([
          for prefix in [
            "ssh-ed25519 ",
            "ssh-rsa ",
            "ecdsa-sha2-nistp256 ",
            "ecdsa-sha2-nistp384 ",
            "ecdsa-sha2-nistp521 ",
            "sk-ecdsa-sha2-nistp256@openssh.com ",
            "sk-ssh-ed25519@openssh.com ",
          ] : startswith(key, prefix)
        ])
      ])
    )
    error_message = "An enabled NFS server requires nonempty, trimmed SSH public keys with an accepted OpenSSH public-key prefix."
  }

  validation {
    condition = !var.nfs_server.enabled || alltrue([
      for address in [var.nfs_server.ip, var.nfs_server.gateway] :
      address == trimspace(address) &&
      !strcontains(address, "/") &&
      length(split(".", address)) == 4 &&
      can(cidrhost("${address}/32", 0))
    ])
    error_message = "An enabled NFS server requires plain IPv4 address and gateway values without CIDR suffixes."
  }

  validation {
    condition = !var.nfs_server.enabled || (
      var.nfs_server.vm_id == floor(var.nfs_server.vm_id) &&
      var.nfs_server.vm_id >= 100 &&
      var.nfs_server.vm_id <= 999999999
    )
    error_message = "An enabled NFS server requires an integral Proxmox VM ID from 100 through 999999999."
  }

  validation {
    condition = !var.nfs_server.enabled || alltrue([
      for value in [
        var.nfs_server.host_node,
        var.nfs_server.name,
        var.nfs_server.boot_datastore,
        var.nfs_server.data_datastore,
      ] : value == trimspace(value) && length(value) > 0
    ])
    error_message = "An enabled NFS server requires nonempty host node, name, and datastore values."
  }
}

variable "nodes_config" {
  description = "Per-node configuration map"
  type = map(object({
    host_node                    = optional(string)
    machine_type                 = string
    boot_disk_size_gib           = optional(number)
    ip                           = string
    mac_address                  = optional(string)
    vm_id                        = optional(number)
    ram_dedicated                = optional(number)
    cpu                          = optional(number)
    igpu                         = optional(bool)
    gpu_node_exclusive           = optional(bool)
    gpu_devices                  = optional(list(string))
    longhorn_create_default_disk = optional(bool)
    extra_labels                 = optional(map(string))
    gpu_device_meta = optional(map(object({
      id           = string
      subsystem_id = string
      iommu_group  = number
    })))
    disks = optional(map(object({
      device      = optional(string)
      size        = optional(string)
      type        = optional(string)
      mountpoint  = optional(string)
      unit_number = optional(number)
    })))
  }))
  default = {
    "k8s-cp-01" = {
      machine_type = "controlplane"
      ip           = "192.168.1.201"
      vm_id        = 101
    }
    "k8s-worker-01" = {
      machine_type = "worker"
      ip           = "192.168.1.211"
      vm_id        = 201
    }
  }
}
