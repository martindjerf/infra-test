output "cluster_id" {
  description = "ID of the cluster"
  value = civo_kubernetes_cluster.this.id
}

output "kubeconfig" {
  description = "kubeconfig"
  value = civo_kubernetes_cluster.this.kubeconfig
  sensitive = true
}