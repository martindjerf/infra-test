output "cluster_id" {
  value = module.cluster.cluster_id
}

output "kubeconfig" {
  value = module.cluster.kubeconfig
  sensitive = true
}