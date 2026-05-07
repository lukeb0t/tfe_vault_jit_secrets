# ─── Identity ──────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Unique name prefix applied to all resources created by this module (e.g. 'cisa-vault-poc')."
  type        = string
}

# ─── Vault ─────────────────────────────────────────────────────────────────

variable "vault_version" {
  description = "Vault Enterprise Docker image tag to pull from Docker Hub (e.g. '2.0.0-ent')."
  type        = string
  default     = "2.0.0-ent"
}

variable "vault_license" {
  description = "Vault Enterprise license string. Passed to the container as the VAULT_LICENSE environment variable."
  type        = string
  sensitive   = true
}

# ─── Networking ────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "ID of the existing VPC where the Vault EC2 instance will be deployed."
  type        = string
}

variable "subnet_id" {
  description = "ID of the existing public subnet where the Vault EC2 instance will be placed."
  type        = string
}

variable "vault_ingress_cidr_blocks" {
  description = "CIDR blocks permitted to reach Vault on port 8200 (HTTPS API + UI)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidr_blocks" {
  description = "CIDR blocks permitted to SSH into the instance on port 22. Set to [] to disable SSH ingress entirely (use SSM Session Manager instead)."
  type        = list(string)
  default     = []
}

# ─── EC2 ───────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "EC2 instance type for the Vault server."
  type        = string
  default     = "m5.large"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair to associate with the instance for SSH access. Leave null to skip (use SSM Session Manager instead)."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Size in GiB of the root EBS volume. Raft storage shares this volume."
  type        = number
  default     = 50
}

# ─── KMS ───────────────────────────────────────────────────────────────────

variable "kms_key_deletion_window_days" {
  description = "Waiting period in days before the KMS unseal key is permanently deleted after a Terraform destroy."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

# ─── SSM ───────────────────────────────────────────────────────────────────

variable "ssm_path_prefix" {
  description = "Leading path segment for all SSM Parameter Store entries created by the cloud-init script (e.g. '/vault'). The cluster_name is appended automatically."
  type        = string
  default     = "/vault"
}

# ─── Tags ──────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Additional resource tags merged onto every resource created by this module."
  type        = map(string)
  default     = {}
}
