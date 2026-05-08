# ─── Vault Connection ──────────────────────────────────────────────────────
# These are not provider arguments — they are used to document the expected
# provider configuration. Configure the Vault provider in your root module.

variable "vault_addr" {
  description = "Address of the Vault server (e.g. 'https://1.2.3.4:8200'). Used for documentation and TFE workspace variable injection."
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace to operate in. Leave empty for the root namespace."
  type        = string
  default     = ""
}

# ─── TFE / HCP Terraform Identity ─────────────────────────────────────────

variable "tfe_hostname" {
  description = "Hostname of the self-hosted Terraform Enterprise instance (e.g. 'tfe.example.com'). Used as the OIDC discovery URL and bound_issuer."
  type        = string
}

variable "tfe_organization" {
  description = "TFE organization name. Used to scope the JWT bound_claims sub claim."
  type        = string
}

variable "tfe_project" {
  description = "TFE project name. Use '*' to match all projects in the organization."
  type        = string
  default     = "*"
}

variable "tfe_workspace" {
  description = "TFE workspace name. Use '*' to match all workspaces in the project."
  type        = string
  default     = "*"
}

# ─── Vault JWT Auth Backend ────────────────────────────────────────────────

variable "jwt_backend_path" {
  description = "Mount path for the JWT auth backend in Vault."
  type        = string
  default     = "jwt-vault-provider"
}

variable "vault_role_name" {
  description = "Name of the Vault JWT auth role that TFE workspaces will authenticate against."
  type        = string
  default     = "tfe-dynamic-creds"
}

variable "workload_identity_audience" {
  description = "Expected 'aud' claim in TFE workload identity tokens. Must match TFC_VAULT_WORKLOAD_IDENTITY_AUDIENCE if overridden."
  type        = string
  default     = "vault.workload.identity"
}

variable "token_ttl_seconds" {
  description = "Lifetime in seconds of the Vault token issued to TFE. TFE renews this token periodically during a run."
  type        = number
  default     = 1200 # 20 minutes — recommended starting point
}

variable "vault_policy_name" {
  description = "Name of the Vault policy attached to the JWT auth role."
  type        = string
  default     = "tfe-dynamic-creds-policy"
}

variable "secret_paths" {
  description = "Vault secret paths the policy should grant read access to (e.g. ['kv/data/myapp/*']). For the built-in demo KV mount, include kv/data/*."
  type        = list(string)
  default     = ["kv/data/*"]
}

# ─── TFE Workspace Variable Injection ──────────────────────────────────────
# Requires the 'tfe' provider. Set configure_tfe_workspace = true and
# un-comment the tfe provider in versions.tf to enable.

variable "configure_tfe_workspace" {
  description = "When true, create tfe_variable resources to inject dynamic credential environment variables into the target TFE workspace."
  type        = bool
  default     = false
}

variable "tfe_workspace_id" {
  description = "TFE workspace ID to inject environment variables into. Required when configure_tfe_workspace = true."
  type        = string
  default     = ""
}

variable "vault_ca_cert_b64" {
  description = "Base64-encoded PEM CA certificate for Vault. Injected as TFC_VAULT_ENCODED_CACERT when non-empty. Required when Vault uses a self-signed certificate."
  type        = string
  sensitive   = true
  default     = ""
}

# ─── TFE OIDC Discovery TLS (optional) ────────────────────────────────────

variable "tfe_ca_cert_pem" {
  description = "PEM-encoded CA certificate for TFE's self-signed TLS cert. Required when TFE uses a self-signed cert so Vault can verify the OIDC discovery endpoint."
  type        = string
  default     = ""
}

# ─── KV Secrets Mount (optional demo) ─────────────────────────────────────

variable "create_demo_kv_mount" {
  description = "When true, create a KV v2 secrets mount at kv/ as a demonstration target for the TFE workspace."
  type        = bool
  default     = true
}
