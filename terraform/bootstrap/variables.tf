variable "location" {
  type    = string
  default = "eastus"
}

variable "resource_group_name" {
  type    = string
  default = "rg-vpx-infra"
}

variable "gh_owner" {
  description = "GitHub repository owner"
  type        = string
}

variable "gh_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "gh_runner_token" {
  description = "GitHub Actions runner registration token"
  type        = string
  sensitive   = true
}

variable "admin_ssh_public_key" {
  description = "SSH public key for runner VM access"
  type        = string
}

variable "runner_vm_size" {
  type    = string
  default = "Standard_B1s"
}
