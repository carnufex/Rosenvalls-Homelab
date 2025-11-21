locals {
  # Node Configuration
  # Adjust CPU/RAM as needed for your hardware
  control_plane_nodes = {
    "k8s-cp-01" = { id = 101, cpu = 2, ram = 4096, ip = "192.168.1.201" }
    # Uncomment for HA
    # "k8s-cp-02" = { id = 102, cpu = 2, ram = 4096, ip = "192.168.1.202" }
    # "k8s-cp-03" = { id = 103, cpu = 2, ram = 4096, ip = "192.168.1.203" }
  }

  worker_nodes = {
    "k8s-worker-01" = { id = 201, cpu = 4, ram = 8192, ip = "192.168.1.211" }
    "k8s-worker-02" = { id = 202, cpu = 4, ram = 8192, ip = "192.168.1.212" }
  }
  
  # Common Settings
  talos_version = "v1.8.3"
  iso_storage   = "local" # Storage ID where ISOs are stored
}

# We will add VM resources here in the next step once we confirm the Proxmox connection.
