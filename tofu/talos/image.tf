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
  proxmox_image_node = nonsensitive(var.cluster.proxmox_cluster)

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

  non_default_node_image_downloads = {
    for image_node_key in distinct([
      for name, node in var.nodes : "${local.node_schematic_key[name]}|${node.host_node}"
      if node.host_node != local.proxmox_image_node
    ]) : image_node_key => {
      schematic_key = split("|", image_node_key)[0]
      node_name     = split("|", image_node_key)[1]
    }
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
  node_name    = local.proxmox_image_node

  url                     = "${var.image.factory_url}/image/${talos_image_factory_schematic.this[each.key].id}/${var.image.version}/${var.image.platform}-${var.image.arch}.raw.gz"
  file_name               = "talos-${var.image.version}-${each.key}-${var.image.platform}-${var.image.arch}.img"
  decompression_algorithm = "gz"
}

resource "proxmox_virtual_environment_download_file" "per_node" {
  for_each     = local.non_default_node_image_downloads
  content_type = "iso"
  datastore_id = var.image.proxmox_datastore
  node_name    = each.value.node_name

  url                     = "${var.image.factory_url}/image/${talos_image_factory_schematic.this[each.value.schematic_key].id}/${var.image.version}/${var.image.platform}-${var.image.arch}.raw.gz"
  file_name               = "talos-${var.image.version}-${each.value.schematic_key}-${var.image.platform}-${var.image.arch}.img"
  decompression_algorithm = "gz"
}
