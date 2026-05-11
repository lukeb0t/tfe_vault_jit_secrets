variable "region" {
  # AWS region where Vault will be deployed.
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
