output "tfe_workspace_id" {
  description = "ID of the vault-kv-test TFE workspace"
  value       = tfe_workspace.kv_test.id
}

output "tfe_workspace_url" {
  description = "URL of the vault-kv-test TFE workspace"
  value       = "https://${var.tfe_hostname}/app/${var.tfe_org_name}/workspaces/${tfe_workspace.kv_test.name}"
}

output "vault_jwt_backend_path" {
  description = "Vault JWT auth backend path used by TFE workspaces"
  value       = module.dynamic_vault_secrets.jwt_backend_path
}

output "vault_role_name" {
  description = "Vault role name granted to the test workspace"
  value       = module.dynamic_vault_secrets.vault_role_name
}

output "kv_mount_path" {
  description = "Vault KV secrets engine mount path where test secrets were written"
  value       = module.dynamic_vault_secrets.kv_mount_path
}
