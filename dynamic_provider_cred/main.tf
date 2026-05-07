# =============================================================================
# dynamic_provider_cred
#
# Configures Vault to act as an OIDC identity provider trusted by a
# self-hosted Terraform Enterprise (TFE) instance, enabling TFE workspaces
# to authenticate to Vault using workload identity (JWT) tokens and receive
# a short-lived Vault token for use with the Vault Terraform provider.
#
# Reference:
#   https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration
#
# Provider configuration (in your root module):
#   provider "vault" {
#     address = var.vault_addr          # e.g. "https://1.2.3.4:8200"
#     token   = "<root or admin token>" # for initial bootstrap only
#   }
# =============================================================================

# ─── JWT Auth Backend ────────────────────────────────────────────────────────
# Vault trusts TFE as an OIDC identity provider by pointing at TFE's
# OIDC discovery endpoint.

resource "vault_jwt_auth_backend" "tfe" {
  path        = var.jwt_backend_path
  description = "Workload identity JWT auth for Terraform Enterprise (${var.tfe_hostname})"
  type        = "jwt"

  # For self-hosted TFE the discovery URL is the TFE hostname itself.
  oidc_discovery_url = "https://${var.tfe_hostname}"
  bound_issuer       = "https://${var.tfe_hostname}"

  # If TFE uses a self-signed or private CA certificate, provide it here.
  # Retrieve the cert with:
  #   openssl s_client -connect <tfe_hostname>:443 -showcerts </dev/null 2>/dev/null \
  #     | openssl x509 -outform PEM
  # oidc_discovery_ca_pem = file("tfe-ca.pem")
}

# ─── Vault Policy ────────────────────────────────────────────────────────────
# Controls what the TFE-issued Vault token is allowed to do.
# Adjust secret_paths to match the paths your TFE workspaces need to read.

resource "vault_policy" "tfe_workspace" {
  name = var.vault_policy_name

  policy = <<-EOT
    # Required: allow the token to look up, renew, and revoke itself.
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }
    path "auth/token/revoke-self" {
      capabilities = ["update"]
    }

    %{~for p in var.secret_paths}
    path "${p}" {
      capabilities = ["read"]
    }
    %{~endfor}
  EOT
}

# ─── JWT Auth Role ───────────────────────────────────────────────────────────
# Maps a TFE organization / project / workspace combination to a Vault role.
# The sub claim uses glob matching so a single role can cover multiple
# workspaces — tighten bound_claims for production.

resource "vault_jwt_auth_backend_role" "tfe_workspace" {
  backend   = vault_jwt_auth_backend.tfe.path
  role_name = var.vault_role_name
  role_type = "jwt"

  bound_audiences   = [var.workload_identity_audience]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfe_organization}:project:${var.tfe_project}:workspace:${var.tfe_workspace}:run_phase:*"
  }

  # terraform_full_workspace is the recommended user_claim — it encodes org,
  # project, and workspace name, giving each workspace a unique Vault identity.
  user_claim = "terraform_full_workspace"

  token_policies = [vault_policy.tfe_workspace.name]
  token_ttl      = var.token_ttl_seconds

  # Renewable so TFE can extend the token for long-running applies.
  token_renewable = true
}

# ─── Demo KV v2 Mount (optional) ────────────────────────────────────────────
# Provides a concrete secrets mount the TFE workspace policy grants access to.

resource "vault_mount" "kv" {
  count = var.create_demo_kv_mount ? 1 : 0

  path        = "kv"
  type        = "kv-v2"
  description = "KV v2 secrets mount — demonstration target for TFE dynamic creds"
}

# ─── TFE Workspace Variables ──────────────────────────────────────────────────
# Uncomment the tfe provider in versions.tf and set configure_tfe_workspace = true
# to have Terraform inject the required environment variables automatically.
#
# Required env vars written to the TFE workspace:
#   TFC_VAULT_PROVIDER_AUTH        = "true"
#   TFC_VAULT_ADDR                 = <vault_addr>
#   TFC_VAULT_RUN_ROLE             = <vault_role_name>
#
# Optional but required for self-signed Vault TLS:
#   TFC_VAULT_ENCODED_CACERT       = <base64 PEM cert>

resource "tfe_variable" "vault_provider_auth" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
  description  = "Enable Vault dynamic provider credentials for this workspace"
}

resource "tfe_variable" "vault_addr" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_ADDR"
  value        = var.vault_addr
  category     = "env"
  description  = "Vault server address"
}

resource "tfe_variable" "vault_run_role" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_RUN_ROLE"
  value        = vault_jwt_auth_backend_role.tfe_workspace.role_name
  category     = "env"
  description  = "Vault JWT role for plan and apply phases"
}

resource "tfe_variable" "vault_namespace" {
  count = var.configure_tfe_workspace && var.vault_namespace != "" ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_NAMESPACE"
  value        = var.vault_namespace
  category     = "env"
  description  = "Vault namespace (Enterprise)"
}

resource "tfe_variable" "vault_encoded_cacert" {
  count = var.configure_tfe_workspace && var.vault_ca_cert_b64 != "" ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
  description  = "Base64-encoded Vault CA cert — required for self-signed TLS"
}
