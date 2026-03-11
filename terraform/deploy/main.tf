# Single NetScaler VPX on Azure — 2 NICs (management + client)
# Uses azurerm_virtual_machine (legacy) because VPX has no Azure agent;
# the newer azurerm_linux_virtual_machine polls OS provisioning and times out.
# VNet and subnets are created inline (no separate bootstrap module).

# --- Resource Group ---
resource "azurerm_resource_group" "vpx" {
  name     = var.resource_group_name
  location = var.location
}

# --- VNet and Subnets ---
resource "azurerm_virtual_network" "vpx" {
  name                = "vnet-vpx"
  location            = azurerm_resource_group.vpx.location
  resource_group_name = azurerm_resource_group.vpx.name
  address_space       = ["10.254.0.0/16"]
}

resource "azurerm_subnet" "management" {
  name                 = "snet-vpx-mgmt"
  resource_group_name  = azurerm_resource_group.vpx.name
  virtual_network_name = azurerm_virtual_network.vpx.name
  address_prefixes     = ["10.254.10.0/24"]
}

resource "azurerm_subnet" "client" {
  name                 = "snet-vpx-client"
  resource_group_name  = azurerm_resource_group.vpx.name
  virtual_network_name = azurerm_virtual_network.vpx.name
  address_prefixes     = ["10.254.11.0/24"]
}

# --- NSGs ---
resource "azurerm_network_security_group" "management" {
  name                = "nsg-management"
  location            = azurerm_resource_group.vpx.location
  resource_group_name = azurerm_resource_group.vpx.name
}

resource "azurerm_network_security_rule" "mgmt_allow" {
  name                        = "allow-ssh-http-https"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["22", "80", "443"]
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.vpx.name
  network_security_group_name = azurerm_network_security_group.management.name
}

resource "azurerm_subnet_network_security_group_association" "management" {
  subnet_id                 = azurerm_subnet.management.id
  network_security_group_id = azurerm_network_security_group.management.id
}

resource "azurerm_network_security_group" "client" {
  name                = "nsg-client"
  location            = azurerm_resource_group.vpx.location
  resource_group_name = azurerm_resource_group.vpx.name
}

resource "azurerm_network_security_rule" "client_allow" {
  name                        = "allow-http-https"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.vpx.name
  network_security_group_name = azurerm_network_security_group.client.name
}

resource "azurerm_subnet_network_security_group_association" "client" {
  subnet_id                 = azurerm_subnet.client.id
  network_security_group_id = azurerm_network_security_group.client.id
}

# --- Public IPs ---
resource "azurerm_public_ip" "mgmt" {
  name                = "pip-vpx-mgmt"
  location            = azurerm_resource_group.vpx.location
  resource_group_name = azurerm_resource_group.vpx.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "vip" {
  name                = "pip-vpx-vip"
  location            = azurerm_resource_group.vpx.location
  resource_group_name = azurerm_resource_group.vpx.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# --- NICs ---
resource "azurerm_network_interface" "mgmt" {
  name                = "nic-vpx-mgmt"
  location            = azurerm_resource_group.vpx.location
  resource_group_name = azurerm_resource_group.vpx.name

  ip_configuration {
    name                          = "mgmt"
    subnet_id                     = azurerm_subnet.management.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.mgmt_ip
    public_ip_address_id          = azurerm_public_ip.mgmt.id
  }

  depends_on = [azurerm_subnet_network_security_group_association.management]
}

resource "azurerm_network_interface" "client" {
  name                = "nic-vpx-client"
  location            = azurerm_resource_group.vpx.location
  resource_group_name = azurerm_resource_group.vpx.name

  ip_configuration {
    name                          = "client-snip"
    subnet_id                     = azurerm_subnet.client.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.client_ip
    primary                       = true
  }

  ip_configuration {
    name                          = "client-vip"
    subnet_id                     = azurerm_subnet.client.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.client_vip
    public_ip_address_id          = azurerm_public_ip.vip.id
  }

  depends_on = [azurerm_subnet_network_security_group_association.client]
}

# --- Boot Diagnostics Storage ---
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "diag" {
  name                     = "stvpxdiag${random_string.suffix.result}"
  location                 = azurerm_resource_group.vpx.location
  resource_group_name      = azurerm_resource_group.vpx.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "logs" {
  name                  = "vpx-logs"
  storage_account_id    = azurerm_storage_account.diag.id
  container_access_type = "private"
}

# --- VPX VM ---
resource "azurerm_virtual_machine" "vpx" {
  name                         = "vm-vpx"
  location                     = azurerm_resource_group.vpx.location
  resource_group_name          = azurerm_resource_group.vpx.name
  vm_size                      = var.vm_size
  primary_network_interface_id = azurerm_network_interface.mgmt.id

  network_interface_ids = [
    azurerm_network_interface.mgmt.id,
    azurerm_network_interface.client.id,
  ]

  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  identity {
    type = "SystemAssigned"
  }

  storage_image_reference {
    publisher = "citrix"
    offer     = var.vpx_offer
    sku       = var.vpx_sku
    version   = var.vpx_version
  }

  plan {
    name      = var.vpx_sku
    publisher = "citrix"
    product   = var.vpx_offer
  }

  storage_os_disk {
    name              = "osdisk-vpx"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  os_profile {
    computer_name  = "vpx"
    admin_username = "nsroot"
    admin_password = var.nsroot_password
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  boot_diagnostics {
    enabled     = true
    storage_uri = azurerm_storage_account.diag.primary_blob_endpoint
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.management,
    azurerm_subnet_network_security_group_association.client,
  ]
}

# --- Self-signed Lab CA ---
resource "tls_private_key" "lab_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
resource "tls_self_signed_cert" "lab_ca" {
  private_key_pem = tls_private_key.lab_ca.private_key_pem
  subject {
    common_name  = "Lab CA"
    organization = "Lab"
  }
  validity_period_hours = 8760
  is_ca_certificate     = true
  allowed_uses          = ["cert_signing", "crl_signing"]
}
# --- Wildcard cert signed by Lab CA ---
resource "tls_private_key" "wildcard" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
resource "tls_cert_request" "wildcard" {
  private_key_pem = tls_private_key.wildcard.private_key_pem
  subject {
    common_name  = "*.lab.local"
    organization = "Lab"
  }
}
resource "tls_locally_signed_cert" "wildcard" {
  cert_request_pem      = tls_cert_request.wildcard.cert_request_pem
  ca_private_key_pem    = tls_private_key.lab_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.lab_ca.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}
