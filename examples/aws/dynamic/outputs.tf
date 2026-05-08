output "tfe_workspace_id" {
  description = "ID of the demo TFE workspace."
  value       = tfe_workspace.demo.id
}

output "tfe_workspace_url" {
  description = "URL to the TFE workspace in the UI."
  value       = "https://${var.tfe_hostname}/app/${var.tfe_org_name}/workspaces/vault-dynamic-creds-demo"
}

output "dynamic_provider_env_vars" {
  description = "Environment variables to set manually on TFE workspace for dynamic provider credentials."
  value       = module.dynamic_provider_cred.tfe_workspace_env_vars
}

output "dynamic_vault_secrets_env_vars" {
  description = "Environment variables to set manually on TFE workspace for vault-backed AWS secrets."
  value       = module.dynamic_vault_secrets.tfe_workspace_env_vars
  sensitive   = true
}
