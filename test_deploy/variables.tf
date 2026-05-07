variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name prefix applied to all resources (VPC, EC2, KMS, SSM, etc.)."
  type        = string
  default     = "cisa-vault-poc"
}

variable "vault_version" {
  description = "Vault Enterprise Docker image tag (e.g. '2.0.0-ent'). Must match the license's supported platform."
  type        = string
  default     = "2.0.0-ent" # Vault 2.0+ required for modern enterprise licenses
}

variable "vault_license" {
  description = "Vault Enterprise license string. Sensitive — pass via TF_VAR_vault_license or a secrets manager, not hardcoded."
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type for the Vault server."
  type        = string
  default     = "m5.large"
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
