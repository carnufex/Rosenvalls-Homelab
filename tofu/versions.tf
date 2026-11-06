terraform {
  required_version = ">= 1.10.0"

  # State lives in R2, encrypted client-side. Endpoint and credentials come from
  # the environment (AWS_ENDPOINT_URL_S3, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY):
  # scripts/tofu.ps1 locally, the tofu-drift CronJob in the cluster.
  backend "s3" {
    bucket                      = "rosenvall-homelab-backup"
    key                         = "tofu-state/hemma-k8s.tfstate"
    region                      = "auto"
    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  # The state holds the Talos machine secrets (cluster CA keys), so it is never
  # stored unencrypted. Losing tofu-state-passphrase makes the state unreadable.
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox.endpoint
  api_token = coalesce(var.proxmox_api_token, var.proxmox.api_token)
  insecure  = var.proxmox.insecure

  ssh {
    agent    = true
    username = "root"
  }
}

provider "talos" {}
