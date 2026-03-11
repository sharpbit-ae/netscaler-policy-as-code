variable "nsip" {
  description = "NetScaler management IP (NSIP)"
  type        = string
  default     = "10.254.10.10"
}

variable "nsroot_password" {
  description = "nsroot password"
  type        = string
  sensitive   = true
}

variable "snip" {
  description = "Subnet IP for outbound traffic (client NIC)"
  type        = string
  default     = "10.254.11.10"
}

