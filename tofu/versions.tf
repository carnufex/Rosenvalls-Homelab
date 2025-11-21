terraform {
  required_version = ">= 1.6.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.6.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure = true # Self-signed certs are common in homelabs
  
  ssh {
    agent = true
  }
}

provider "talos" {}
