output "aws_secrets_backend_path" {
  description = "Mount path of the Vault AWS secrets engine."
  value       = vault_aws_secret_backend.aws.path
}

output "aws_secrets_role_name" {
  description = "Name of the Vault AWS secrets engine role."
  value       = vault_aws_secret_backend_role.tfe.name
}

output "jwt_backend_path" {
  description = "Mount path of the Vault JWT auth backend."
  value       = vault_jwt_auth_backend.tfe.path
}

output "vault_role_name" {
  description = "Name of the Vault JWT auth role for TFE workspaces."
  value       = vault_jwt_auth_backend_role.tfe.role_name
}

output "vault_policy_name" {
  description = "Name of the Vault policy attached to the JWT auth role."
  value       = vault_policy.tfe_backed_aws.name
}

output "target_iam_role_arn" {
  description = "ARN of the AWS IAM role that Vault assumes to generate dynamic credentials."
  value       = aws_iam_role.vault_target.arn
}

output "tfe_workspace_env_vars" {
  description = "Map of all environment variables to set in the TFE workspace (for reference when configure_tfe_workspace = false)."
  value = {
    TFC_VAULT_PROVIDER_AUTH         = "true"
    TFC_VAULT_ADDR                  = var.vault_addr
    TFC_VAULT_RUN_ROLE              = vault_jwt_auth_backend_role.tfe.role_name
    TFC_VAULT_BACKED_AWS_AUTH       = "true"
    TFC_VAULT_BACKED_AWS_AUTH_TYPE  = "assumed_role"
    TFC_VAULT_BACKED_AWS_ROLE       = vault_aws_secret_backend_role.tfe.name
    TFC_VAULT_BACKED_AWS_MOUNT_PATH = vault_aws_secret_backend.aws.path
    TFC_VAULT_BACKED_AWS_RUN_ROLE   = vault_jwt_auth_backend_role.tfe.role_name
  }
}
