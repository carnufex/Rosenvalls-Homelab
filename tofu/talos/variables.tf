variable "image" {
  description = "Talos image configuration"
  type = object({
    factory_url = optional(string, "https://factory.talos.dev")
    version     = string
    arch        = optional(string, "amd64")
    platform    = optional(string, "nocloud")
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
}
