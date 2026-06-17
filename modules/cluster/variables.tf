variable "region" {
  description = "Region where network is placed"
  type = string

  validation {
    condition = contains(["LON1", "NYC1", "FRA1", "PHX1"], var.region)
    error_message = "Region must be in one of the following locations"
  }
}

variable "cluster_name" {
  description = "Name of the cluster"
  type = string
}

variable "network_id" {
  description = "ID of the network cluster will be placed in"
  type = string
}

variable "firewall_id" {
  description = "ID of the firewall that will be applied to the cluster"
  type = string
}

variable "kubernetes_version" {
  description = "Version of cluster"
  type = string
}

variable "node_pool_label" {
  description = "label for nodes"
  type = string
}

variable "node_size" {
  description = "Size of nodes in cluster"
  type = string
}

variable "node_count" {
  description = "Number of nodes in cluster"
  type = number

  validation {
    condition = var.node_count >= 1 && var.node_count <= 10
    error_message = "Node count must be between 1 and 10"
  }
}