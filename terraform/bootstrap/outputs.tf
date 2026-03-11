output "runner_public_ip" {
  value = azurerm_public_ip.runner.ip_address
}

output "vnet_name" {
  value = azurerm_virtual_network.vpx.name
}

output "vnet_id" {
  value = azurerm_virtual_network.vpx.id
}

output "resource_group_name" {
  value = azurerm_resource_group.infra.name
}
