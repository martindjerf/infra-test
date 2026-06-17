module "network" {
 source = "../../../modules/network"

 firewall_name = var.firewall_name
 network_label = var.network_label
 region = var.region 
}

module "cluster" {
  source = "../../../modules/cluster"

  cluster_name = var.cluster_name
  firewall_id = module.network.firewall_id
  network_id = module.network.network_id
  kubernetes_version = var.kubernetes_version
  node_count = var.node_count
  node_pool_label = var.node_pool_label
  node_size = var.node_size
  region = var.region
}