variable "region" {
  # AWS region where Vault and TFE will be deployed.
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  # Shared name prefix for the demo deployment.
  type    = string
  default = "jit-demo"
}

variable "vault_license" {
  # Vault Enterprise license string.
  type      = string
  sensitive = true
}

variable "tfe_license" {
  # Terraform Enterprise license string.
  type      = string
  sensitive = true
}

variable "admin_email" {
  # Email address for the initial TFE admin user.
  type = string
}

variable "admin_password" {
  # Initial password for the TFE admin user.
  type      = string
  sensitive = true
}

variable "tfe_org_name" {
  # Organization name created in Terraform Enterprise.
  type    = string
  default = "hashicorp-demo"
}

variable "key_pair_name" {
  # Optional EC2 key pair for SSH access.
  type    = string
  default = null
}

variable "vault_tls_cert_pem" {
  # Optional PEM-encoded TLS certificate for Vault listener.
  # Leave empty to let the module generate a self-signed cert.
  type      = string
  sensitive = true
  default   = ""
}

variable "vault_tls_key_pem" {
  # Optional PEM-encoded private key for vault_tls_cert_pem.
  # Leave empty to let the module generate a self-signed key.
  type      = string
  sensitive = true
  default   = ""
}
