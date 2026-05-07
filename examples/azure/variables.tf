variable "cluster_name" {
  description = "Unique name prefix for all Azure resources."
  type        = string
  default     = "vault-poc"
}

variable "vault_version" {
  description = "Vault Enterprise Docker image tag."
  type        = string
  default     = "2.0.0-ent"
}

variable "vault_license" {
  description = "Vault Enterprise license string. Pass via TF_VAR_vault_license or tfvars."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region (e.g. 'East US')."
  type        = string
  default     = "East US"
}

variable "resource_group_name" {
  description = "Existing Azure Resource Group to deploy into."
  type        = string
}

variable "admin_ssh_public_key" {
  description = "SSH public key string for the azureuser account."
  type        = string
}
