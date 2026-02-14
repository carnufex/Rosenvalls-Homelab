# State migration: move existing singleton resources to keyed versions
moved {
  from = talos_image_factory_schematic.this
  to   = talos_image_factory_schematic.this["std"]
}

moved {
  from = proxmox_virtual_environment_download_file.this
  to   = proxmox_virtual_environment_download_file.this["std"]
}

locals {
  has_gpu_nodes = anytrue([for name, node in var.nodes : lookup(node, "igpu", false)])

  # One schematic per type: "std" always, "gpu" only if any node needs it
  schematic_configs = merge(
    {
      "std" = { needs_nvidia_extensions = false }
    },
    local.has_gpu_nodes ? {
      "gpu" = { needs_nvidia_extensions = true }
    } : {}
  )

  # Map each node to its schematic type
  node_schematic_key = {
    for name, node in var.nodes :
    name => lookup(node, "igpu", false) ? "gpu" : "std"
  }
}

resource "talos_image_factory_schematic" "this" {
  for_each = local.schematic_configs

  schematic = templatefile("${path.module}/image/schematic.yaml.tftpl", {
    needs_nvidia_extensions = each.value.needs_nvidia_extensions
  })
}

resource "proxmox_virtual_environment_download_file" "this" {
  for_each     = local.schematic_configs
  content_type = "iso"
  datastore_id = var.image.proxmox_datastore
  node_name    = var.cluster.proxmox_cluster

  url                     = "${var.image.factory_url}/image/${talos_image_factory_schematic.this[each.key].id}/${var.image.version}/${var.image.platform}-${var.image.arch}.raw.gz"
  file_name               = "talos-${var.image.version}-${each.key}-${var.image.platform}-${var.image.arch}.img"
  decompression_algorithm = "gz"
}
