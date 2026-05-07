output "vault_addr" {
  description = "Vault HTTPS address — set as VAULT_ADDR."
  value       = module.vault.vault_addr
}

output "vault_public_ip" {
  description = "Static public IP of the Vault server."
  value       = module.vault.vault_public_ip
}

output "key_vault_name" {
  description = "Azure Key Vault name — contains root token and recovery keys."
  value       = module.vault.key_vault_name
}

output "key_vault_uri" {
  description = "Azure Key Vault URI."
  value       = module.vault.key_vault_uri
}

output "retrieve_root_token_cmd" {
  description = "Azure CLI command to retrieve the Vault root token from Key Vault."
  value       = "az keyvault secret show --vault-name ${module.vault.key_vault_name} --name vault-root-token --query value -o tsv"
}

output "vnet_id" {
  description = "VNet ID used by this deployment."
  value       = module.vault.vnet_id
}
