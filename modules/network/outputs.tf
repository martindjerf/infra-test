output "network_id" {
  description = "ID of the network"
  value       = civo_network.this.id
}

output "firewall_id" {
  description = "ID of the firewall"
  value       = civo_firewall.this.id
}