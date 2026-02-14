data "talos_machine_configuration" "this" {
  for_each         = var.nodes
  cluster_name     = var.cluster.name
  cluster_endpoint = "https://${var.cluster.endpoint}:6443"
  machine_type     = each.value.machine_type
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.cluster.talos_version
  config_patches = concat(
    [
      templatefile("${path.module}/machine-config/${each.value.machine_type}.yaml.tftpl", {
        disks              = each.value.disks
        cilium_values      = var.cilium.values
        cilium_install     = var.cilium.install
        vip                = var.cluster.endpoint
        hostname           = each.key
        node_ip            = each.value.ip
        gateway            = var.cluster.gateway
        igpu               = each.value.igpu
        gpu_node_exclusive = lookup(each.value, "gpu_node_exclusive", false)
      })
    ],
    # Conditionally add GPU patches for GPU-enabled worker nodes
    lookup(each.value, "igpu", false) ? [
      file("${path.module}/patches/gpu-modules.yaml"),
      file("${path.module}/patches/gpu-runtime.yaml")
    ] : []
  )
}

resource "talos_machine_configuration_apply" "this" {
  depends_on = [proxmox_virtual_environment_vm.this]
  for_each   = var.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration
  node                        = each.value.ip

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.this[each.key]]
  }
}
