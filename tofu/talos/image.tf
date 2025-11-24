resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent", "siderolabs/iscsi-tools"]
      }
    }
  })
}

resource "proxmox_virtual_environment_download_file" "this" {
  content_type = "iso"
  datastore_id = var.image.proxmox_datastore
  node_name    = var.cluster.proxmox_cluster

  url       = "${var.image.factory_url}/image/${talos_image_factory_schematic.this.id}/${var.image.version}/${var.image.platform}-${var.image.arch}.raw.gz"
  file_name = "talos-${var.image.version}-${var.image.platform}-${var.image.arch}.img"
  decompression_algorithm = "gz"
}
