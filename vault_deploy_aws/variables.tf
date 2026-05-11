# ─── Identity ──────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Unique name prefix applied to all resources created by this module (e.g. 'cisa-vault-poc')."
  type        = string
}

# ─── Vault ─────────────────────────────────────────────────────────────────

variable "vault_version" {
  description = "Vault Enterprise Docker image tag to pull from Docker Hub (e.g. '2.0.0-ent')."
  type        = string
  # Vault 2.0.0+ is required for licenses using the 'platform-standard' module.
  # Versions 1.18.x and earlier will reject modern enterprise licenses.
  default = "2.0.0-ent"
}

variable "vault_license" {
  description = "Vault Enterprise license string. Passed to the container as the VAULT_LICENSE environment variable."
  type        = string
  sensitive   = true # prevents the license from appearing in plan/apply output or state diffs
}

# ─── Networking ────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "ID of an existing VPC to deploy into. If null (default), the module creates a new VPC using vpc_cidr. When provided, subnet_id must also be supplied."
  type        = string
  default     = null # null = module manages its own VPC
}

variable "subnet_id" {
  description = "ID of an existing public subnet. Required when vpc_id is provided; ignored when vpc_id is null (the module creates a subnet automatically)."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC created by this module. Only used when vpc_id is null."
  type        = string
  default     = "10.100.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet created by this module. Only used when vpc_id is null."
  type        = string
  default     = "10.100.1.0/24"
}

variable "vault_ingress_cidr_blocks" {
  description = "CIDR blocks permitted to reach Vault on port 8200 (HTTPS API + UI)."
  type        = list(string)
  default     = ["0.0.0.0/0"] # restrict to known CIDRs in production
}

variable "ssh_ingress_cidr_blocks" {
  description = "CIDR blocks permitted to SSH into the instance on port 22. Set to [] to disable SSH ingress entirely (use SSM Session Manager instead)."
  type        = list(string)
  default     = [] # SSM-only by default — no SSH port exposed
}

# ─── EC2 ───────────────────────────────────────────────────────────────────

variable "barebones_dev_mode" {
  description = "When true, disable KMS auto-unseal and SSM bootstrap storage, use Shamir unseal with one key share, and require key_pair_name for SSH access."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type for the Vault server."
  type        = string
  default     = "m5.medium" # 1 vCPU / 4 GB — lower-cost default for single-node POC
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair to associate with the instance for SSH access. Required when barebones_dev_mode is true; leave null to skip otherwise."
  type        = string
  default     = null # prefer SSM over SSH; set only if SSH access is explicitly required
}

variable "root_volume_size_gb" {
  description = "Size in GiB of the root EBS volume. Raft storage shares this volume."
  type        = number
  default     = 50
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

variable "tls_disable_client_certs" {
  description = "Whether Vault should disable client certificate requests on the HTTPS listener."
  type        = bool
  default     = true
}

# ─── KMS ───────────────────────────────────────────────────────────────────

variable "kms_key_deletion_window_days" {
  description = "Waiting period in days before the KMS unseal key is permanently deleted after a Terraform destroy."
  type        = number
  default     = 30 # maximum safety window; reduce to 7 for lab environments

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

# ─── SSM ───────────────────────────────────────────────────────────────────

variable "ssm_path_prefix" {
  description = "Leading path segment for all SSM Parameter Store entries created by the cloud-init script (e.g. '/vault'). The cluster_name is appended automatically."
  type        = string
  default     = "/vault" # results in /vault/<cluster_name>/root_token etc.
}

# ─── Tags ──────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Additional resource tags merged onto every resource created by this module."
  type        = map(string)
  default     = {}
}
