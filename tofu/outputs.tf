resource "local_file" "talosconfig" {
  content         = module.talos.client_configuration.talos_config
  filename        = "${path.module}/output/talosconfig"
  file_permission = "0600"
}

resource "local_file" "kubeconfig" {
  content         = module.talos.kube_config.kubeconfig_raw
  filename        = "${path.module}/output/kubeconfig"
  file_permission = "0600"
}

output "talosconfig" {
  value     = module.talos.client_configuration.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = module.talos.kube_config.kubeconfig_raw
  sensitive = true
}

output "nfs_server" {
  description = "Connection details for the dedicated NFS server"
  value = var.nfs_server.enabled ? {
    name   = var.nfs_server.name
    vm_id  = var.nfs_server.vm_id
    ip     = var.nfs_server.ip
    export = "${var.nfs_server.ip}:/srv/nfs/immich"
  } : null
}
