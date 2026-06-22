output "cluster_id" {
  description = "ID of the cluster"
  value       = civo_kubernetes_cluster.this.id
}

output "kubeconfig" {
  description = "kubeconfig"
  value       = civo_kubernetes_cluster.this.kubeconfig
  sensitive   = true
}

output "velero_bucket_url" {
  description = "URL of the Velero backup bucket"
  value       = civo_object_store.velero.bucket_url
}

output "velero_access_key_id" {
  description = "Access key ID for velero bucket"
  value       = civo_object_store_credential.velero.access_key_id
  sensitive   = true
}

output "velero_secret_access_key" {
  description = "Secret access key for Velero bucket"
  value       = civo_object_store_credential.velero.secret_access_key
  sensitive   = true
}