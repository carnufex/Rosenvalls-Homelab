resource "talos_machine_secrets" "this" {
  talos_version = var.cluster.talos_version

  # The cluster PKI, bootstrap token and etcd/secretbox secrets are generated ONCE.
  # talos_version here only selects the secrets *format* at generation time; without
  # this, every Talos version bump makes the plan regenerate all cluster secrets
  # ("known after apply"), which would lock every node out of the running cluster.
  # A cold rebuild creates the resource fresh, so it still gets the current version.
  lifecycle {
    ignore_changes = [talos_version]
  }
}
