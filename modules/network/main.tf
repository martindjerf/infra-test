resource "civo_network" "this" {
  label = var.network_label
  region = var.region
}

resource "civo_firewall" "this" {
  name = var.firewall_name
  network_id = civo_network.this.id
  region = var.region
  create_default_rules = false

  ingress_rule {
    label = "k8s-api"
    protocol = "tcp"
    port_range = "6443"
    cidr = [ "0.0.0.0/0" ]
    action = "allow"
  }

  egress_rule {
    label = "all-outbound"
    protocol = "tcp"
    port_range = "1-65535"
    cidr = [ "0.0.0.0/0" ]
    action = "allow"
  }
}