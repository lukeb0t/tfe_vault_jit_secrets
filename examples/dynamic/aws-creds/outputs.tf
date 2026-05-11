output "tfe_workspace_id" {
  description = "ID of the aws-creds-test TFE workspace"
  value       = tfe_workspace.aws_test.id
}

output "tfe_workspace_url" {
  description = "URL of the aws-creds-test TFE workspace"
  value       = "https://${var.tfe_hostname}/app/${var.tfe_org_name}/workspaces/${tfe_workspace.aws_test.name}"
}

output "vault_jwt_backend_path" {
  description = "Vault JWT auth backend path used by TFE workspaces"
  value       = module.dynamic_aws_provider_secrets.jwt_backend_path
}

output "vault_role_name" {
  description = "Vault role name granted to the test workspace"
  value       = module.dynamic_aws_provider_secrets.vault_role_name
}

output "aws_secrets_backend_path" {
  description = "Vault AWS secrets engine mount path"
  value       = module.dynamic_aws_provider_secrets.aws_secrets_backend_path
}

output "aws_secrets_role_name" {
  description = "Vault AWS secrets engine role name used for STS credential generation"
  value       = module.dynamic_aws_provider_secrets.aws_secrets_role_name
}

output "target_iam_role_arn" {
  description = "ARN of the IAM role TFE workspaces will assume via Vault"
  value       = module.dynamic_aws_provider_secrets.target_iam_role_arn
}
