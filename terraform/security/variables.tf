variable "nsip" {
  description = "NetScaler management IP (NSIP)"
  type        = string
  default     = "10.254.10.10"
}

variable "nsroot_password" {
  description = "nsroot password (from Key Vault)"
  type        = string
  sensitive   = true
}

variable "snip" {
  description = "Subnet IP for outbound traffic (client NIC)"
  type        = string
  default     = "10.254.11.10"
}

variable "vip" {
  description = "Virtual IP (client NIC secondary)"
  type        = string
  default     = "10.254.11.11"
}
