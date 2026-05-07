variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name prefix applied to all resources."
  type        = string
  default     = "vault-poc"
}

variable "vault_version" {
  description = "Vault Enterprise Docker image tag (e.g. '2.0.0-ent')."
  type        = string
  default     = "2.0.0-ent"
}

variable "vault_license" {
  description = "Vault Enterprise license string. Pass via TF_VAR_vault_license — do not hardcode."
  type        = string
  sensitive   = true
}
