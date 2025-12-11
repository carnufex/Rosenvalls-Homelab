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
  default     = "v1.8.3"
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

variable "nodes_config" {
  description = "Per-node configuration map"
  type = map(object({
    host_node     = optional(string)
    machine_type  = string
    ip            = string
    mac_address   = optional(string)
    vm_id         = optional(number)
    ram_dedicated = optional(number)
    cpu           = optional(number)
    igpu          = optional(bool)
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
      machine_type  = "controlplane"
      ip            = "192.168.1.201"
      vm_id         = 101
    }
    "k8s-worker-01" = {
      machine_type  = "worker"
      ip            = "192.168.1.211"
      vm_id         = 201
    }
  }
}
