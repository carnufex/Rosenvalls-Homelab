proxmox = {
  name         = "desktop" # Namnet på din Proxmox-nod (där VM:arna ska bo)
  cluster_name = "desktop" # MÅSTE vara samma som nod-namnet för att ISO-lagring ska fungera
  endpoint     = "https://192.168.1.111:8006/"
  insecure     = true
  username     = "root@pam"
}

# Inställningar för det NYA Kubernetes-klustret
cluster_name     = "hemma-k8s"     # Namnet på ditt Kubernetes-kluster
cluster_endpoint = "192.168.1.200" # En LEDIG IP-adress som blir VIP (Virtual IP) för klustret
gateway          = "192.168.1.1"
talos_version    = "v1.14.4"

nodes_config = {
  "control-01" = {
    host_node          = "desktop"
    machine_type       = "controlplane"
    boot_disk_size_gib = 20
    # Synced to the live VM 2026-11-06: the disk was moved/edited by hand in Proxmox.
    boot_discard  = "ignore"
    ip            = "192.168.1.201" # IP för kontrollpanelen
    vm_id         = 8001
    cpu           = 2
    ram_dedicated = 6144
    igpu          = false
    extra_labels = {
      "homelab.rosenvall.se/proxmox-host" = "desktop"
      "topology.kubernetes.io/zone"       = "desktop"
    }
  }
  "worker-01" = {
    host_node          = "desktop"
    machine_type       = "worker"
    boot_disk_size_gib = 48
    # The disk was moved to desktop-lagring by hand in Proxmox (synced 2026-11-06).
    # discard=on (2026-11-07) lets fstrim inside Talos return freed blocks to the
    # qcow2 file, which lives on the desktop host's root filesystem.
    boot_datastore_id = "desktop-lagring"
    boot_file_format  = "qcow2"
    boot_discard      = "on"
    ip                = "192.168.1.211"
    vm_id             = 8002
    cpu               = 6
    ram_dedicated     = 8192
    igpu              = false
    extra_labels = {
      "homelab.rosenvall.se/lan-special"  = "true"
      "homelab.rosenvall.se/proxmox-host" = "desktop"
      "topology.kubernetes.io/zone"       = "desktop"
    }
  }
  "worker-02" = {
    host_node          = "desktop"
    machine_type       = "worker"
    boot_disk_size_gib = 20
    # The disk was moved to desktop-lagring by hand in Proxmox (synced 2026-11-06).
    # discard=on (2026-11-07) lets fstrim inside Talos return freed blocks to the
    # qcow2 file, which lives on the desktop host's root filesystem.
    boot_datastore_id = "desktop-lagring"
    boot_file_format  = "qcow2"
    boot_discard      = "on"
    ip                = "192.168.1.212" # IP för arbetarnoden 2
    vm_id             = 8003
    cpu               = 4
    ram_dedicated     = 8192
    igpu              = false
    extra_labels = {
      "homelab.rosenvall.se/proxmox-host" = "desktop"
      "topology.kubernetes.io/zone"       = "desktop"
    }
  }
  "worker-03" = {
    host_node          = "desktop"
    machine_type       = "worker"
    boot_disk_size_gib = 64
    # Synced to the live VM 2026-11-06: the disk was moved/edited by hand in Proxmox.
    boot_discard  = "ignore"
    ip            = "192.168.1.213" # Temporär arbetarnod för rolling rebuild
    vm_id         = 8004
    cpu           = 4
    ram_dedicated = 6144
    igpu          = false
    disks = {
      longhorn = {
        datastore_id = "WD-red" # live: the Longhorn disk sits on the WD Red, not local-lvm
      }
    }
    extra_labels = {
      "homelab.rosenvall.se/proxmox-host" = "desktop"
      "topology.kubernetes.io/zone"       = "desktop"
    }
  }
  "worker-04" = {
    host_node                    = "host1"
    machine_type                 = "worker"
    longhorn_create_default_disk = false
    boot_disk_size_gib           = 32
    ip                           = "192.168.1.214"
    vm_id                        = 8005
    cpu                          = 4
    ram_dedicated                = 12288
    igpu                         = false
    disks = {
      longhorn = {
        device      = "/dev/sdb"
        size        = "30G"
        type        = "scsi"
        mountpoint  = "/var/lib/longhorn"
        unit_number = 1
      }
    }
    extra_labels = {
      "homelab.rosenvall.se/memory-tier"  = "large"
      "homelab.rosenvall.se/proxmox-host" = "host1"
      "topology.kubernetes.io/zone"       = "host1"
    }
  }
  "worker-05" = {
    host_node                    = "clevoP150SM"
    machine_type                 = "worker"
    longhorn_create_default_disk = false
    boot_disk_size_gib           = 32
    ip                           = "192.168.1.217"
    vm_id                        = 8006
    cpu                          = 4
    ram_dedicated                = 6144 # live Proxmox value (2026-11-06)
    igpu                         = false
    disks                        = {}
    extra_labels = {
      "homelab.rosenvall.se/compute-only" = "true"
      "homelab.rosenvall.se/proxmox-host" = "clevoP150SM"
      "topology.kubernetes.io/zone"       = "clevoP150SM"
    }
  }
  "worker-06" = {
    host_node                    = "htpc"
    machine_type                 = "worker"
    longhorn_create_default_disk = false
    boot_disk_size_gib           = 32
    ip                           = "192.168.1.218"
    vm_id                        = 8007
    cpu                          = 3
    ram_dedicated                = 4096 # live Proxmox value (2026-11-06)
    igpu                         = false
    disks                        = {}
    extra_labels = {
      "homelab.rosenvall.se/compute-only" = "true"
      "homelab.rosenvall.se/proxmox-host" = "htpc"
      "topology.kubernetes.io/zone"       = "htpc"
    }
  }
  "worker-07" = {
    host_node                    = "elitedesk1"
    machine_type                 = "worker"
    longhorn_create_default_disk = true
    boot_disk_size_gib           = 32
    ip                           = "192.168.1.219"
    vm_id                        = 8008
    cpu                          = 2
    ram_dedicated                = 6144 # live Proxmox value (2026-11-06)
    igpu                         = false
    disks = {
      longhorn = {
        size = "80G" # 2026-11-06: worker-07 becomes a Longhorn node (pool 78 % even if this disk fills)
      }
    }
    extra_labels = {
      "homelab.rosenvall.se/proxmox-host" = "elitedesk1"
      "topology.kubernetes.io/zone"       = "elitedesk1"
    }
  }
  "control-02" = {
    host_node          = "clevoP150SM"
    machine_type       = "controlplane"
    boot_disk_size_gib = 32
    ip                 = "192.168.1.202"
    vm_id              = 8009
    cpu                = 2
    ram_dedicated      = 6144
    igpu               = false
    extra_labels = {
      "homelab.rosenvall.se/proxmox-host" = "clevoP150SM"
      "topology.kubernetes.io/zone"       = "clevoP150SM"
    }
  }
  "control-03" = {
    host_node          = "eliteDesk2"
    machine_type       = "controlplane"
    boot_disk_size_gib = 32
    ip                 = "192.168.1.203"
    vm_id              = 8012
    cpu                = 2
    ram_dedicated      = 6144
    igpu               = false
    extra_labels = {
      "homelab.rosenvall.se/proxmox-host" = "eliteDesk2"
      "topology.kubernetes.io/zone"       = "eliteDesk2"
    }
  }
  "worker-08" = {
    host_node                    = "clevoP150SM"
    machine_type                 = "worker"
    longhorn_create_default_disk = false
    boot_disk_size_gib           = 32
    ip                           = "192.168.1.232"
    vm_id                        = 8013
    cpu                          = 2
    ram_dedicated                = 6144 # live Proxmox value (2026-11-06)
    igpu                         = false
    disks                        = {}
    extra_labels = {
      "homelab.rosenvall.se/compute-only" = "true"
      "homelab.rosenvall.se/proxmox-host" = "clevoP150SM"
      "topology.kubernetes.io/zone"       = "clevoP150SM"
    }
  }
  "worker-09" = {
    host_node                    = "eliteDesk2"
    machine_type                 = "worker"
    longhorn_create_default_disk = false
    boot_disk_size_gib           = 32
    ip                           = "192.168.1.233"
    vm_id                        = 8014
    cpu                          = 2
    ram_dedicated                = 8192
    igpu                         = false
    disks                        = {}
    extra_labels = {
      "homelab.rosenvall.se/compute-only" = "true"
      "homelab.rosenvall.se/proxmox-host" = "eliteDesk2"
      "topology.kubernetes.io/zone"       = "eliteDesk2"
    }
  }
}

nfs_server = {
  enabled            = true
  host_node          = "desktop"
  vm_id              = 8011
  name               = "nfs-01"
  ip                 = "192.168.1.231"
  gateway            = "192.168.1.1"
  boot_datastore     = "local-lvm"
  data_datastore     = "WD-red"
  data_disk_size_gib = 2048
  agent_enabled      = true
  ssh_public_keys    = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPVVQjiZC/WRKO5h5HdQZS3Cmz+qebdKrn0IRtsQrSmF"]
}
