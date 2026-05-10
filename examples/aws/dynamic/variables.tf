variable "region" {
  # AWS region for Terraform resources in this configuration.
  type    = string
  default = "us-east-1"
}

variable "vault_addr" {
  # Vault HTTPS address, for example https://1.2.3.4:8200.
  type = string
}

variable "vault_root_token" {
  # Vault root token used for initial bootstrap only.
  type      = string
  sensitive = true
  default   = ""
}

variable "vault_ca_cert_b64" {
  # Base64-encoded Vault PEM certificate for TFE workspace injection.
  type      = string
  sensitive = true
  default   = ""
}

variable "vault_root_token_ssm_path" {
  # Optional SSM SecureString path for the Vault root token.
  # Used only when vault_root_token is empty.
  type    = string
  default = ""
}

variable "vault_ca_cert_b64_ssm_path" {
  # Optional SSM String path for the base64 Vault TLS cert.
  # Used only when vault_ca_cert_b64 is empty.
  type    = string
  default = ""
}

variable "vault_iam_role_arn" {
  # ARN of the Vault EC2 IAM role allowed to assume the demo target role.
  type = string
  default = ""
}

variable "vault_iam_principal_arn" {
  # ARN of the IAM principal Vault authenticates as (role or user).
  # Preferred over vault_iam_role_arn; falls back for compatibility.
  type    = string
  default = ""
}

variable "vault_aws_access_key_id" {
  # Optional AWS access key ID for Vault AWS secrets engine root config.
  type      = string
  sensitive = true
  default   = ""
}

variable "vault_aws_secret_access_key" {
  # Optional AWS secret access key for Vault AWS secrets engine root config.
  type      = string
  sensitive = true
  default   = ""
}

variable "tfe_hostname" {
  # Terraform Enterprise hostname, for example 1.2.3.4.nip.io.
  type = string
}

variable "tfe_org_token" {
  # TFE organization API token used to manage the workspace.
  type      = string
  sensitive = true
}

variable "tfe_org_name" {
  # Terraform Enterprise organization name.
  type    = string
  default = "hashicorp-demo"
}

variable "aws_region" {
  # AWS region used by the Vault AWS secrets engine.
  type    = string
  default = "us-east-1"
}

variable "tfe_ca_cert_pem" {
  description = "PEM-encoded CA certificate for TFE's self-signed TLS cert. Required when TFE uses a self-signed cert."
  type        = string
  default     = ""
}
