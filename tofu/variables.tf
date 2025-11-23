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

variable "nodes" {
  description = "Configuration for cluster nodes"
  type = map(object({
    host_node     = string
    machine_type  = string
    datastore_id  = optional(string)
    ip            = string
    mac_address   = optional(string)
    vm_id         = optional(number)
    cpu           = number
    ram_dedicated = number
    igpu          = optional(bool, false)
  }))
  default = {
    "k8s-cp-01" = {
      host_node     = "pve"
      machine_type  = "controlplane"
      ip            = "192.168.1.201"
      vm_id         = 101
      cpu           = 2
      ram_dedicated = 4096
    }
    "k8s-worker-01" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.211"
      vm_id         = 201
      cpu           = 4
      ram_dedicated = 8192
    }
  }
}
