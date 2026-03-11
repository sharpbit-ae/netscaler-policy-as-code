variable "nsip" {
  description = "NetScaler management IP"
  type        = string
  default     = "10.254.10.10"
}

variable "nsroot_password" {
  description = "nsroot password"
  type        = string
  sensitive   = true
}

variable "vip" {
  description = "Virtual IP for the LB vservers"
  type        = string
  default     = "10.254.11.11"
}

variable "lab_ca_crt" {
  description = "Lab CA certificate PEM (base64 encoded)"
  type        = string
  sensitive   = true
}

variable "wildcard_crt" {
  description = "Wildcard certificate PEM (base64 encoded)"
  type        = string
  sensitive   = true
}

variable "wildcard_key" {
  description = "Wildcard private key PEM (base64 encoded)"
  type        = string
  sensitive   = true
}
