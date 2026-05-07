variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "cisa-vault-poc"
}

variable "vault_version" {
  type    = string
  default = "1.18.3-ent"
}

variable "vault_license" {
  description = "Vault Enterprise license string."
  type        = string
  sensitive   = true
}

variable "instance_type" {
  type    = string
  default = "m5.large"
}

variable "tags" {
  type    = map(string)
  default = {}
}
