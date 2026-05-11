variable "vault_addr" {
  description = "Vault server URL (e.g. https://vault.example.com:8200)"
  type        = string
}

variable "vault_root_token" {
  description = "Vault root/admin token used to configure the JWT backend and AWS secrets engine"
  type        = string
  sensitive   = true
}

variable "vault_ca_cert_b64" {
  description = "Base64-encoded CA certificate for the Vault server. Leave empty for publicly-signed certs."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vault_iam_role_arn" {
  description = "ARN of the Vault EC2/instance IAM role allowed to assume the demo target role (legacy alias)."
  type        = string
  default     = ""
}

variable "vault_iam_principal_arn" {
  description = "ARN of the IAM principal Vault authenticates as (role or user). Preferred over vault_iam_role_arn."
  type        = string
  default     = ""
}

variable "vault_aws_access_key_id" {
  description = "Optional AWS access key ID for Vault AWS secrets engine root config. Leave empty to use instance role."
  type        = string
  sensitive   = true
  default     = ""
}

variable "vault_aws_secret_access_key" {
  description = "Optional AWS secret access key for Vault AWS secrets engine root config. Leave empty to use instance role."
  type        = string
  sensitive   = true
  default     = ""
}

variable "aws_region" {
  description = "AWS region for the Vault AWS secrets engine backend."
  type        = string
  default     = "us-east-1"
}

variable "tfe_hostname" {
  description = "Hostname of your TFE/TFC instance (e.g. app.terraform.io or tfe.example.com)"
  type        = string
}

variable "tfe_org_token" {
  description = "TFE organization token used to create workspaces and upload configurations"
  type        = string
  sensitive   = true
}

variable "tfe_org_name" {
  description = "TFE/TFC organization name"
  type        = string
}

variable "tfe_ca_cert_pem" {
  description = "PEM-encoded CA certificate for the TFE server. Leave empty for publicly-signed certs."
  type        = string
  default     = ""
  sensitive   = true
}
