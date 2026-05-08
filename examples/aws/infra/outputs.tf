output "vault_addr" {
  description = "Vault API address."
  value       = module.vault.vault_addr
}

output "vault_public_ip" {
  description = "Vault public Elastic IP."
  value       = module.vault.vault_public_ip
}

output "vault_root_token_ssm_path" {
  description = "SSM path containing the Vault root token."
  value       = module.vault.ssm_root_token_path
}

output "vault_tls_cert_b64_ssm_path" {
  description = "SSM path containing the base64-encoded Vault TLS certificate."
  value       = module.vault.ssm_tls_cert_b64_path
}

output "vault_iam_role_arn" {
  description = "IAM role ARN attached to the Vault instance."
  value       = module.vault.iam_role_arn
}

output "tfe_url" {
  description = "Terraform Enterprise URL."
  value       = module.tfe.tfe_url
}

output "tfe_hostname" {
  description = "Terraform Enterprise hostname."
  value       = module.tfe.tfe_hostname
}

output "tfe_org_token_ssm_path" {
  description = "SSM path containing the TFE organization token."
  value       = module.tfe.ssm_org_token_path
}

output "tfe_admin_token_ssm_path" {
  description = "SSM path containing the TFE admin token."
  value       = module.tfe.ssm_admin_token_path
}
