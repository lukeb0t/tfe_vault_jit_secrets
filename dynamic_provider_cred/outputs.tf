output "jwt_backend_path" {
  description = "Mount path of the Vault JWT auth backend."
  value       = vault_jwt_auth_backend.tfe.path
}

output "jwt_backend_accessor" {
  description = "Accessor of the Vault JWT auth backend."
  value       = vault_jwt_auth_backend.tfe.accessor
}

output "vault_role_name" {
  description = "Name of the Vault JWT auth role for TFE workspaces."
  value       = vault_jwt_auth_backend_role.tfe_workspace.role_name
}

output "vault_policy_name" {
  description = "Name of the Vault policy attached to the TFE auth role."
  value       = vault_policy.tfe_workspace.name
}

output "kv_mount_path" {
  description = "Mount path of the demo KV v2 secrets engine (null if not created)."
  value       = var.create_demo_kv_mount ? vault_mount.kv[0].path : null
}

output "tfe_workspace_env_vars" {
  description = "Map of environment variable names and values to set in the TFE workspace (for reference when configure_tfe_workspace = false)."
  value = {
    TFC_VAULT_PROVIDER_AUTH = "true"
    TFC_VAULT_ADDR          = var.vault_addr
    TFC_VAULT_RUN_ROLE      = vault_jwt_auth_backend_role.tfe_workspace.role_name
    TFC_VAULT_NAMESPACE     = var.vault_namespace
    TFC_VAULT_AUTH_PATH     = var.jwt_backend_path
  }
}
