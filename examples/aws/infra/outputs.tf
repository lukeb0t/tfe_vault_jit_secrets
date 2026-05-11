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
