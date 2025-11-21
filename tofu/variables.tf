variable "proxmox_endpoint" {
  type        = string
  description = "The endpoint for the Proxmox Virtual Environment API (e.g., https://192.168.1.10:8006/)"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "The API token for the Proxmox Virtual Environment API (format: USER@REALM!TOKENID=UUID)"
}

variable "target_node" {
  type        = string
  description = "The name of the Proxmox node to deploy VMs on"
}

variable "cluster_name" {
  type        = string
  default     = "rosenvall-homelab"
  description = "Name of the Kubernetes cluster"
}
