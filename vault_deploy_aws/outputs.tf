output "vault_addr" {
  description = "HTTPS address of the Vault server (use as VAULT_ADDR)."
  value       = "https://${aws_eip.vault.public_ip}:8200"
}

output "vault_public_ip" {
  description = "Elastic IP address assigned to the Vault server."
  value       = aws_eip.vault.public_ip
}

output "instance_id" {
  description = "EC2 instance ID of the Vault server."
  value       = aws_instance.vault.id
}

output "security_group_id" {
  description = "ID of the security group attached to the Vault server."
  value       = aws_security_group.vault.id
}

output "iam_role_arn" {
  description = "ARN of the IAM role attached to the Vault EC2 instance."
  value       = aws_iam_role.vault.arn
}

output "kms_key_id" {
  description = "ID of the KMS key used for Vault auto-unseal."
  value       = aws_kms_key.vault.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for Vault auto-unseal."
  value       = aws_kms_key.vault.arn
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix where Vault secrets are stored by cloud-init."
  value       = local.ssm_prefix
}

output "ssm_root_token_path" {
  description = "Full SSM Parameter Store path of the Vault root token (SecureString)."
  value       = "${local.ssm_prefix}/root_token"
}

output "vault_tls_cert_host_path" {
  description = "Path on the EC2 host where the self-signed TLS cert is stored. Retrieve it via SSM Session Manager to set VAULT_CACERT locally."
  value       = "/opt/vault/certs/vault.crt"
}

# ─── Networking outputs (useful when the module created the VPC) ─────────────

output "vpc_id" {
  description = "ID of the VPC used by this deployment (created by module or provided via var.vpc_id)."
  value       = local.vpc_id_resolved
}

output "subnet_id" {
  description = "ID of the public subnet used by this deployment."
  value       = local.subnet_id_resolved
}
