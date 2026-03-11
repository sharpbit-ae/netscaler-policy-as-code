# Bootstrap: VNet, runner VM, and state storage
# Run once from existing self-hosted runner

# --- Resource Group ---
resource "azurerm_resource_group" "infra" {
  name     = var.resource_group_name
  location = var.location
}

# --- Networking ---
resource "azurerm_virtual_network" "vpx" {
  name                = "vnet-vpx"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
  address_space       = ["10.254.0.0/16"]
}

resource "azurerm_subnet" "runner" {
  name                 = "snet-runner"
  resource_group_name  = azurerm_resource_group.infra.name
  virtual_network_name = azurerm_virtual_network.vpx.name
  address_prefixes     = ["10.254.1.0/24"]
}

resource "azurerm_subnet" "vpx_mgmt" {
  name                 = "snet-vpx-mgmt"
  resource_group_name  = azurerm_resource_group.infra.name
  virtual_network_name = azurerm_virtual_network.vpx.name
  address_prefixes     = ["10.254.10.0/24"]
}

resource "azurerm_subnet" "vpx_client" {
  name                 = "snet-vpx-client"
  resource_group_name  = azurerm_resource_group.infra.name
  virtual_network_name = azurerm_virtual_network.vpx.name
  address_prefixes     = ["10.254.11.0/24"]
}

# --- Runner NSG ---
resource "azurerm_network_security_group" "runner" {
  name                = "nsg-runner"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
}

resource "azurerm_network_security_rule" "runner_ssh" {
  name                        = "allow-ssh"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.infra.name
  network_security_group_name = azurerm_network_security_group.runner.name
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

# --- Runner VM ---
resource "azurerm_public_ip" "runner" {
  name                = "pip-runner"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-runner"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name

  ip_configuration {
    name                          = "runner"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.runner.id
  }

  depends_on = [azurerm_subnet_network_security_group_association.runner]
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                = "vm-runner"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
  size                = var.runner_vm_size

  admin_username = "azureuser"

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.admin_ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.runner.id]

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    gh_owner        = var.gh_owner
    gh_repo         = var.gh_repo
    gh_runner_token = var.gh_runner_token
  }))
}
