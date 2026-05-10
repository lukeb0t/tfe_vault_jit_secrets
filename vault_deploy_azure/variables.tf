# ─── Identity ────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Unique name prefix applied to all Azure resources created by this module."
  type        = string
}

# ─── Vault ───────────────────────────────────────────────────────────────────

variable "vault_version" {
  description = "Vault Enterprise Docker image tag (e.g. '2.0.0-ent'). Must be 2.0.0+ for modern enterprise licenses."
  type        = string
  # Vault 2.0.0+ required for licenses using the 'platform-standard' module.
  default = "2.0.0-ent"
}

variable "vault_license" {
  description = "Vault Enterprise license string. Sensitive — pass via TF_VAR_vault_license or a secrets manager, never hardcoded."
  type        = string
  sensitive   = true
}

# ─── Azure Location & Resource Group ─────────────────────────────────────────

variable "location" {
  description = "Azure region for all resources (e.g. 'East US', 'West Europe')."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the existing Azure Resource Group where all resources will be created."
  type        = string
}

# ─── Networking ──────────────────────────────────────────────────────────────

variable "vnet_id" {
  description = "Resource ID of an existing VNet. If null (default), the module creates a new VNet using vnet_cidr. When provided, subnet_id must also be supplied."
  type        = string
  default     = null # null = module manages its own VNet
}

variable "subnet_id" {
  description = "Resource ID of an existing subnet. Required when vnet_id is provided; ignored when vnet_id is null (the module creates a subnet automatically)."
  type        = string
  default     = null
}

variable "vnet_cidr" {
  description = "Address space for the VNet created by this module. Only used when vnet_id is null."
  type        = string
  default     = "10.100.0.0/16"
}

variable "subnet_cidr" {
  description = "Address prefix for the subnet created by this module. Only used when vnet_id is null."
  type        = string
  default     = "10.100.1.0/24"
}

variable "vault_ingress_cidr_blocks" {
  description = "CIDR ranges allowed to reach Vault on port 8200 (HTTPS API + UI). Restrict to known IPs in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidr_blocks" {
  description = "CIDR ranges allowed to SSH (port 22). Leave empty to disable — use Azure Bastion or Serial Console instead."
  type        = list(string)
  default     = [] # SSH-less by default; prefer Azure Bastion for production access
}

# ─── VM ──────────────────────────────────────────────────────────────────────

variable "vm_size" {
  description = "Azure VM size for the Vault server."
  type        = string
  default     = "Standard_D2s_v3" # 2 vCPU / 8 GiB — equivalent to AWS m5.large
}

variable "admin_ssh_public_key" {
  description = "SSH public key string for the 'azureuser' account (e.g. 'ssh-rsa AAAA...'). Required by Azure even when SSH access is not used."
  type        = string
}

variable "vault_tls_cert_pem" {
  description = "Optional PEM-encoded TLS certificate for Vault listener. When set, vault_tls_key_pem must also be set. If empty, cloud-init generates a self-signed cert."
  type        = string
  sensitive   = true
  default     = ""
}

variable "vault_tls_key_pem" {
  description = "Optional PEM-encoded private key for Vault listener TLS certificate. When set, vault_tls_cert_pem must also be set."
  type        = string
  sensitive   = true
  default     = ""
}

variable "os_disk_size_gb" {
  description = "Size in GiB of the OS disk. Vault Raft storage shares this disk."
  type        = number
  default     = 50
}

# ─── Key Vault ────────────────────────────────────────────────────────────────
# Azure Key Vault serves both purposes that AWS uses two services for:
#   - Auto-unseal key   (AWS: KMS Customer Managed Key)
#   - Root token storage (AWS: SSM Parameter Store SecureString)

variable "key_vault_name" {
  description = "Override for the Azure Key Vault name. If null, defaults to '<cluster_name>-kv' (truncated to 24 chars). Must be globally unique across Azure."
  type        = string
  default     = null
}

variable "soft_delete_retention_days" {
  description = "Days to retain soft-deleted Key Vault objects before permanent removal (7–90). Use 7 for lab environments."
  type        = number
  default     = 7 # minimum; increase to 90 for production

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}

variable "purge_protection_enabled" {
  description = "Enable purge protection. Recommended true in production to prevent permanent key loss; false for lab teardown convenience."
  type        = bool
  default     = false # set true in production
}

# ─── Tags ────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Additional tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}
