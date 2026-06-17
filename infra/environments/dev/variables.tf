variable "region" {
  description = "region of infrastructure"
  type = string
  default = "LON1"
}

variable "cluster_name" {
  description = "clustername"
  type = string
}

variable "network_label" {
  type = string
}

variable "firewall_name" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "node_pool_label" {
  type = string
}

variable "node_size" {
  type = string
}

variable "node_count" {
  type = number
}