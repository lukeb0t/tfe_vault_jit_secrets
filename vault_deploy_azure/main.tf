data "azurerm_client_config" "current" {}

locals {
  # Azure Key Vault names: 3–24 chars, alphanumeric + hyphens, globally unique.
  # Truncate to 24 characters to stay within Azure's hard limit.
  key_vault_name     = var.key_vault_name != null ? var.key_vault_name : substr("${var.cluster_name}-kv", 0, 24)
  key_vault_key_name = "vault-unseal"

  # When vnet_id is null the module creates its own VNet and subnet.
  # When vnet_id is provided the caller must also supply subnet_id.
  create_networking  = var.vnet_id == null
  vnet_id_resolved   = local.create_networking ? azurerm_virtual_network.vault[0].id : var.vnet_id
  subnet_id_resolved = local.create_networking ? azurerm_subnet.vault_public[0].id : var.subnet_id
  custom_tls_enabled = var.vault_tls_cert_pem != "" && var.vault_tls_key_pem != ""
  barebones_enabled  = var.barebones_dev_mode
  key_vault_enabled  = !local.barebones_enabled
  bootstrap_dir      = "/opt/vault/bootstrap"

  common_tags = merge(
    {
      Module      = "vault_deploy_azure"
      ClusterName = var.cluster_name
    },
    var.tags
  )
}

# ─── VNet & Networking (managed — only created when vnet_id is not supplied) ──

resource "azurerm_virtual_network" "vault" {
  count               = local.create_networking ? 1 : 0
  name                = "${var.cluster_name}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_cidr]
  tags                = merge(local.common_tags, { Name = "${var.cluster_name}-vnet" })
}

resource "azurerm_subnet" "vault_public" {
  count                = local.create_networking ? 1 : 0
  name                 = "${var.cluster_name}-public"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vault[0].name
  address_prefixes     = [var.subnet_cidr]
}

# ─── Azure Key Vault ──────────────────────────────────────────────────────────
# Serves two purposes — equivalent to two separate AWS services:
#   1. Auto-unseal key    → AWS KMS Customer Managed Key
#   2. Root token storage → AWS SSM Parameter Store (SecureString)
# RBAC authorization is used instead of legacy access policies (modern default).

resource "azurerm_key_vault" "vault" {
  count = local.key_vault_enabled ? 1 : 0

  name                       = local.key_vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "premium" # premium supports HSM-backed keys
  enable_rbac_authorization  = true      # use Azure RBAC, not legacy access policies
  soft_delete_retention_days = var.soft_delete_retention_days
  purge_protection_enabled   = var.purge_protection_enabled # true recommended in production

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-kv" })
}

# Grant the Terraform deployer Key Vault Administrator so it can create and
# manage the unseal key during apply/destroy.
resource "azurerm_role_assignment" "deployer_kv_admin" {
  count = local.key_vault_enabled ? 1 : 0

  scope                = azurerm_key_vault.vault[0].id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC role assignments can take up to 30 seconds to propagate.
# Without this wait, the key creation immediately following will fail with 403 Forbidden.
resource "time_sleep" "rbac_propagation" {
  count = local.key_vault_enabled ? 1 : 0

  depends_on      = [azurerm_role_assignment.deployer_kv_admin]
  create_duration = "30s"
}

# RSA key used by Vault's azurekeyvault seal to wrap/unwrap the master key
# on every init and unseal operation.
resource "azurerm_key_vault_key" "vault_unseal" {
  count = local.key_vault_enabled ? 1 : 0

  depends_on = [time_sleep.rbac_propagation]

  name         = local.key_vault_key_name
  key_vault_id = azurerm_key_vault.vault[0].id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey"] # asymmetric wrapping required for Vault auto-unseal

  tags = local.common_tags
}

# ─── User-Assigned Managed Identity ──────────────────────────────────────────
# The VM uses this identity to:
#   1. Authenticate to Key Vault for auto-unseal (wrapKey / unwrapKey)
#   2. Store the Vault root token as a Key Vault secret after init
# User-assigned (vs system-assigned) keeps the identity lifecycle independent
# of the VM — the identity and its RBAC assignments survive VM re-creation.

resource "azurerm_user_assigned_identity" "vault" {
  count = local.key_vault_enabled ? 1 : 0

  name                = "${var.cluster_name}-vault-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

# Allows the managed identity to wrap/unwrap the unseal key.
# Vault's azurekeyvault seal calls wrapKey on init and unwrapKey on every unseal.
resource "azurerm_role_assignment" "vault_kv_crypto" {
  count = local.key_vault_enabled ? 1 : 0

  scope                = azurerm_key_vault.vault[0].id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.vault[0].principal_id
}

# Allows the managed identity to create and read Key Vault secrets.
# Used by cloud-init to store the root token and recovery keys after vault operator init.
resource "azurerm_role_assignment" "vault_kv_secrets" {
  count = local.key_vault_enabled ? 1 : 0

  scope                = azurerm_key_vault.vault[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.vault[0].principal_id
}

# ─── Network Security Group ───────────────────────────────────────────────────

resource "azurerm_network_security_group" "vault" {
  name                = "${var.cluster_name}-vault-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.common_tags, { Name = "${var.cluster_name}-vault-nsg" })
}

# Always allow inbound traffic on the Vault HTTPS API / UI port.
resource "azurerm_network_security_rule" "vault_api" {
  name                        = "allow-vault-api"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8200"
  source_address_prefixes     = var.vault_ingress_cidr_blocks
  destination_address_prefix  = "*"
  description                 = "Vault HTTPS API and UI"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vault.name
}

# SSH rule only created when ssh_ingress_cidr_blocks is non-empty.
# Prefer Azure Bastion or Serial Console for production shell access.
resource "azurerm_network_security_rule" "ssh" {
  count = length(var.ssh_ingress_cidr_blocks) > 0 ? 1 : 0

  name                        = "allow-ssh"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.ssh_ingress_cidr_blocks
  destination_address_prefix  = "*"
  description                 = "SSH — prefer Azure Bastion or Serial Console in production"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vault.name
}

# ─── Public IP ────────────────────────────────────────────────────────────────
# Allocated before the VM — same pattern as AWS EIP pre-allocation.
# The IP is embedded into the TLS SAN and Vault api_addr at cloud-init
# render time, so both are correct before the VM even boots.

resource "azurerm_public_ip" "vault" {
  name                = "${var.cluster_name}-vault-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"   # static ensures the IP doesn't change on stop/start
  sku                 = "Standard" # Standard SKU required for zone redundancy and NSG association
  tags                = merge(local.common_tags, { Name = "${var.cluster_name}-vault-pip" })
}

# ─── Network Interface ────────────────────────────────────────────────────────

resource "azurerm_network_interface" "vault" {
  name                = "${var.cluster_name}-vault-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id_resolved
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vault.id
  }
}

# Associate the NSG at the NIC level rather than subnet level to avoid
# affecting other resources that may share the same subnet.
resource "azurerm_network_interface_security_group_association" "vault" {
  network_interface_id      = azurerm_network_interface.vault.id
  network_security_group_id = azurerm_network_security_group.vault.id
  # NSG at NIC level (not subnet) avoids affecting other VNet resources.
}

# ─── Linux Virtual Machine ───────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "vault" {
  name                = "${var.cluster_name}-vault"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = "azureuser"

  network_interface_ids = [azurerm_network_interface.vault.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.admin_ssh_public_key
  }

  # Key Vault mode needs a user-assigned managed identity; barebones mode skips it.
  dynamic "identity" {
    for_each = local.key_vault_enabled ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.vault[0].id]
    }
  }

  # custom_data runs the bootstrap script via cloud-init on first boot.
  # Azure replaces the VM when custom_data changes (equivalent to
  # user_data_replace_on_change = true in the AWS module).
  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.sh.tpl", {
    cluster_name               = var.cluster_name
    vault_version              = var.vault_version
    vault_license              = var.vault_license
    tenant_id                  = local.key_vault_enabled ? data.azurerm_client_config.current.tenant_id : ""
    key_vault_name             = local.key_vault_enabled ? local.key_vault_name : ""
    key_vault_key_name         = local.key_vault_enabled ? local.key_vault_key_name : ""
    managed_identity_client_id = local.key_vault_enabled ? azurerm_user_assigned_identity.vault[0].client_id : ""
    barebones_dev_mode         = local.barebones_enabled ? "true" : "false"
    bootstrap_dir              = local.bootstrap_dir
    vault_api_addr             = azurerm_public_ip.vault.ip_address
    vault_use_custom_tls       = local.custom_tls_enabled ? "true" : "false"
    vault_tls_cert_pem_b64     = local.custom_tls_enabled ? base64encode(var.vault_tls_cert_pem) : ""
    vault_tls_key_pem_b64      = local.custom_tls_enabled ? base64encode(var.vault_tls_key_pem) : ""
    tls_disable_client_certs   = var.tls_disable_client_certs ? "true" : "false"
  }))

  os_disk {
    name                 = "${var.cluster_name}-vault-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS" # consistent IOPS baseline — equivalent to AWS gp3
    disk_size_gb         = var.os_disk_size_gb
  }

  # Ubuntu 22.04 LTS (Jammy) — supported until April 2027, widely available
  # across all Azure regions and pre-installed with cloud-init.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vault" })

  lifecycle {
    precondition {
      condition     = !var.barebones_dev_mode || length(var.ssh_ingress_cidr_blocks) > 0
      error_message = "barebones_dev_mode requires at least one SSH ingress CIDR block so operators can retrieve /opt/vault/bootstrap/init.json."
    }

    precondition {
      condition = (
        (var.vault_tls_cert_pem == "" && var.vault_tls_key_pem == "") ||
        (var.vault_tls_cert_pem != "" && var.vault_tls_key_pem != "")
      )
      error_message = "vault_tls_cert_pem and vault_tls_key_pem must both be set together, or both left empty."
    }
  }
}
