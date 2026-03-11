output "mgmt_public_ip" {
  value = azurerm_public_ip.mgmt.ip_address
}

output "vip_public_ip" {
  value = azurerm_public_ip.vip.ip_address
}

output "mgmt_private_ip" {
  value = var.mgmt_ip
}

output "snip" {
  value = var.client_ip
}

output "vip" {
  value = var.client_vip
}

output "storage_account_name" {
  value = azurerm_storage_account.diag.name
}

output "resource_group_name" {
  value = azurerm_resource_group.vpx.name
}

output "lab_ca_crt_b64" {
  value     = base64encode(tls_self_signed_cert.lab_ca.cert_pem)
  sensitive = true
}

output "wildcard_crt_b64" {
  value     = base64encode(tls_locally_signed_cert.wildcard.cert_pem)
  sensitive = true
}

output "wildcard_key_b64" {
  value     = base64encode(tls_private_key.wildcard.private_key_pem)
  sensitive = true
}
