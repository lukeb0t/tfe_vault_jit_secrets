output "vault_addr" {
  description = "HTTPS address of the Vault server (use as VAULT_ADDR)."
  value       = "https://${azurerm_public_ip.vault.ip_address}:8200"
}

output "vault_public_ip" {
  description = "Static public IP address of the Vault server."
  value       = azurerm_public_ip.vault.ip_address
}

output "vm_id" {
  description = "Azure resource ID of the Vault virtual machine."
  value       = azurerm_linux_virtual_machine.vault.id
}

output "managed_identity_id" {
  description = "Azure resource ID of the user-assigned managed identity attached to the VM."
  value       = azurerm_user_assigned_identity.vault.id
}

output "managed_identity_principal_id" {
  description = "Object (principal) ID of the managed identity — use when granting it additional RBAC roles."
  value       = azurerm_user_assigned_identity.vault.principal_id
}

output "managed_identity_client_id" {
  description = "Client ID of the user-assigned managed identity."
  value       = azurerm_user_assigned_identity.vault.client_id
}

output "key_vault_id" {
  description = "Azure resource ID of the Key Vault used for auto-unseal and secret storage."
  value       = azurerm_key_vault.vault.id
}

output "key_vault_uri" {
  description = "URI of the Azure Key Vault (e.g. https://<name>.vault.azure.net/)."
  value       = azurerm_key_vault.vault.vault_uri
}

output "key_vault_name" {
  description = "Name of the Azure Key Vault."
  value       = local.key_vault_name
}

output "key_vault_root_token_secret_name" {
  description = "Name of the Key Vault secret where the Vault root token is stored by cloud-init."
  value       = "vault-root-token"
}

output "vault_tls_cert_host_path" {
  description = "Path on the VM host where the self-signed TLS cert is stored. Retrieve via SSH or Azure Serial Console to use as VAULT_CACERT."
  value       = "/opt/vault/certs/vault.crt"
}

# ─── Networking outputs ──────────────────────────────────────────────────────

output "vnet_id" {
  description = "ID of the VNet used by this deployment (created by module or provided via var.vnet_id)."
  value       = local.vnet_id_resolved
}

output "subnet_id" {
  description = "ID of the subnet used by this deployment."
  value       = local.subnet_id_resolved
}
