# =============================================================================
# dynamic_provider_cred
#
# Configures Vault JWT auth to trust workload identity (JWT) tokens issued by a
# self-hosted Terraform Enterprise (TFE) instance, enabling TFE workspaces to
# exchange their run token for a short-lived Vault token that the Vault
# Terraform provider can use during plan/apply.
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
# Vault trusts TFE's workload identity issuer by pointing at TFE's
# OIDC discovery endpoint (https://<tfe_hostname>/.well-known/openid-configuration).
# Vault fetches the JWKS from this URL to verify incoming JWT signatures.

resource "vault_jwt_auth_backend" "tfe" {
  path        = var.jwt_backend_path
  description = "Workload identity JWT auth for Terraform Enterprise (${var.tfe_hostname})"
  type        = "jwt"

  # For self-hosted TFE the discovery URL is the TFE hostname itself.
  # Vault will append /.well-known/openid-configuration automatically.
  oidc_discovery_url = "https://${var.tfe_hostname}"
  bound_issuer       = "https://${var.tfe_hostname}" # must match the 'iss' claim in TFE JWTs

  # Provide the TFE CA cert so Vault can verify the OIDC discovery endpoint TLS.
  # Required when TFE uses a self-signed certificate (e.g., self-hosted TFE).
  oidc_discovery_ca_pem = var.tfe_ca_cert_pem != "" ? var.tfe_ca_cert_pem : null
}

# ─── Vault Policy ────────────────────────────────────────────────────────────
# Controls what the TFE-issued Vault token is allowed to do.
# Adjust secret_paths to match the paths your TFE workspaces need to read.

resource "vault_policy" "tfe_workspace" {
  name = var.vault_policy_name

  policy = <<-EOT
    # Required: allow the token to look up, renew, and revoke itself.
    # TFE's dynamic credentials protocol calls these paths automatically.
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

  # vault.workload.identity is the default audience TFE uses; override with
  # TFC_VAULT_WORKLOAD_IDENTITY_AUDIENCE in the workspace if you change this.
  bound_audiences   = [var.workload_identity_audience]
  bound_claims_type = "glob" # enables wildcard matching in bound_claims values

  # The sub claim encodes org, project, workspace, and run phase.
  # Using "*" for workspace matches all workspaces — scope this in production.
  bound_claims = {
    sub = "organization:${var.tfe_organization}:project:${var.tfe_project}:workspace:${var.tfe_workspace}:run_phase:*"
  }

  # terraform_full_workspace encodes the full org/project/workspace path,
  # giving each workspace a unique identity in Vault audit logs.
  user_claim = "terraform_full_workspace"

  token_policies = [vault_policy.tfe_workspace.name]
  token_ttl      = var.token_ttl_seconds
}

# ─── Demo KV v2 Mount (optional) ────────────────────────────────────────────
# Provides a concrete secrets mount the TFE workspace policy grants access to.
# Disable with create_demo_kv_mount = false when using your own secrets mounts.

resource "vault_mount" "kv" {
  count = var.create_demo_kv_mount ? 1 : 0

  path        = "kv"
  type        = "kv-v2"
  description = "KV v2 secrets mount — demonstration target for TFE dynamic creds"
}

# ─── TFE Workspace Variables ──────────────────────────────────────────────────
# Injects the required TFC_VAULT_* environment variables into the target
# TFE workspace so any run can exchange its workload-identity JWT for a
# Vault token via the jwt-vault-provider backend.
#
#   TFC_VAULT_PROVIDER_AUTH  = "true"
#   TFC_VAULT_ADDR           = <vault_addr>
#   TFC_VAULT_AUTH_PATH      = <jwt_backend_path>  (default: jwt-vault-provider)
#   TFC_VAULT_RUN_ROLE       = <vault_role_name>
#   TFC_VAULT_NAMESPACE      = <vault_namespace>   (omitted for root namespace)
#   TFC_VAULT_ENCODED_CACERT = <base64 PEM>        (omitted when not provided)

resource "tfe_variable" "vault_provider_auth" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
  description  = "Enable Vault dynamic provider credentials for this workspace"
}

resource "tfe_variable" "vault_addr" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_ADDR"
  value        = var.vault_addr
  category     = "env"
  description  = "Vault server address"
}

resource "tfe_variable" "vault_run_role" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_RUN_ROLE"
  value        = vault_jwt_auth_backend_role.tfe_workspace.role_name
  category     = "env"
  description  = "Vault JWT role for plan and apply phases"
}

resource "tfe_variable" "vault_namespace" {
  # Only inject namespace when one is set — root namespace needs no variable.
  count = var.vault_namespace != "" ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_NAMESPACE"
  value        = var.vault_namespace
  category     = "env"
  description  = "Vault namespace (Enterprise)"
}

resource "tfe_variable" "vault_auth_path" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_AUTH_PATH"
  value        = vault_jwt_auth_backend.tfe.path
  category     = "env"
  description  = "Vault JWT auth backend mount path"
}

resource "tfe_variable" "vault_encoded_cacert" {
  # Only inject the CA cert when one is provided — omit for public CA-signed certs.
  count = var.vault_ca_cert_b64 != "" ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
  description  = "Base64-encoded Vault CA cert — required for self-signed TLS"
}
