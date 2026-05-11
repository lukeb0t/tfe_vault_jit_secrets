variable "vault_addr" {
  description = "Vault server URL (e.g. https://vault.example.com:8200)"
  type        = string
}

variable "vault_root_token" {
  description = "Vault root/admin token used to configure the JWT backend and KV policy"
  type        = string
  sensitive   = true
}

variable "vault_ca_cert_b64" {
  description = "Base64-encoded CA certificate for the Vault server. Leave empty for publicly-signed certs."
  type        = string
  default     = ""
  sensitive   = true
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
