output "cluster_id" {
  value = module.cluster.cluster_id
}

output "kubeconfig" {
  value     = module.cluster.kubeconfig
  sensitive = true
}

output "velero_bucket_url" {
  description = "URL of the Velero backup bucket"
  value       = module.cluster.velero_bucket_url
}

output "velero_access_key_id" {
  description = "Access key ID for velero bucket"
  value       = module.cluster.velero_access_key_id
  sensitive   = true
}

output "velero_secret_access_key" {
  description = "Secret access key for Velero bucket"
  value       = module.cluster.velero_secret_access_key
  sensitive   = true
}