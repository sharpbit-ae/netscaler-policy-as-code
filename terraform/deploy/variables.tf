variable "location" {
  type    = string
  default = "eastus"
}

variable "resource_group_name" {
  type    = string
  default = "rg-vpx"
}

variable "infra_resource_group_name" {
  description = "Resource group containing the VNet (created by bootstrap)"
  type        = string
  default     = "rg-vpx-infra"
}

variable "nsroot_password" {
  description = "VPX nsroot password"
  type        = string
  sensitive   = true
}

variable "rpc_password" {
  description = "VPX RPC node password"
  type        = string
  sensitive   = true
}

variable "mgmt_allowed_cidrs" {
  description = "Additional CIDRs allowed SSH/HTTPS to management (e.g. your public IP)"
  type        = list(string)
  default     = []
}

variable "vm_size" {
  type    = string
  default = "Standard_D2s_v3"
}

variable "vpx_offer" {
  type    = string
  default = "netscalervpx-141"
}

variable "vpx_sku" {
  type    = string
  default = "netscalerbyol"
}

variable "vpx_version" {
  description = "Marketplace image version"
  type        = string
  default     = "latest"
}

variable "mgmt_ip" {
  type    = string
  default = "10.254.10.10"
}

variable "client_ip" {
  type    = string
  default = "10.254.11.10"
}

variable "client_vip" {
  type    = string
  default = "10.254.11.11"
}
