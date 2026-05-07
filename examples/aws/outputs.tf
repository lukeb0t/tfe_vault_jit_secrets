output "vault_addr" {
  description = "Vault HTTPS address."
  value       = module.vault.vault_addr
}

output "vault_public_ip" {
  description = "Elastic IP of the Vault instance."
  value       = module.vault.vault_public_ip
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.vault.instance_id
}

output "vpc_id" {
  description = "VPC created by the module."
  value       = module.vault.vpc_id
}

output "ssm_root_token_path" {
  description = "SSM path to retrieve the Vault root token."
  value       = module.vault.ssm_root_token_path
}

output "kms_key_id" {
  description = "KMS key used for auto-unseal."
  value       = module.vault.kms_key_id
}
