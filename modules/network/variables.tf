variable "region" {
  description = "Region where network is placed"
  type = string

  validation {
    condition = contains(["LON1", "NYC1", "FRA1", "PHX1"], var.region)
    error_message = "Region must be in one of the following locations"
  }
}

variable "network_label" {
  description = "network label"
  type = string
}

variable "firewall_name" {
  description = "name of firewall"
  type = string
}