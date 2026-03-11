terraform {
  required_version = ">= 1.5"

  backend "azurerm" {}

  required_providers {
    citrixadc = {
      source  = "citrix/citrixadc"
      version = "~> 1.45"
    }
  }
}

provider "citrixadc" {
  endpoint             = "https://${var.nsip}"
  username             = "nsroot"
  password             = var.nsroot_password
  insecure_skip_verify = true
}
