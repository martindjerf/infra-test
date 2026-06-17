resource "civo_kubernetes_cluster" "this" {
  name = var.cluster_name
  region = var.region
  network_id = var.network_id
  firewall_id = var.firewall_id
  kubernetes_version = var.kubernetes_version
  write_kubeconfig = false

  pools {
    label = var.node_pool_label
    size = var.node_size
    node_count = var.node_count
  }
}