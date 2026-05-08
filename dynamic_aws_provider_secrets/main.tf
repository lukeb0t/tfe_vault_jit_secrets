# =============================================================================
# dynamic_aws_provider_secrets
#
# Configures Vault-backed dynamic AWS credentials for Terraform Enterprise.
# TFE workspaces authenticate to Vault via JWT workload identity, receive a
# short-lived Vault token, then request AWS credentials from Vault's AWS
# secrets engine; TFE injects the resulting STS credentials into the workspace
# environment without any static AWS keys.
#
# Architecture:
#   TFE → (JWT) → Vault JWT auth → Vault token
#   TFE → (Vault token) → Vault AWS secrets engine → STS credentials
#   TFE → (STS creds injected as env vars) → AWS provider
#
# Reference:
#   https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws
#   https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-backed/aws-configuration
#
# Provider configuration (in your root module):
#   provider "vault" {
#     address = var.vault_addr
#     token   = "<root or admin token>"
#   }
#   provider "aws" {
#     region = var.aws_secrets_backend_region
#     # credentials for the AWS account where the target IAM role lives
#   }
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  # Use a read-only demo policy when no custom policy is supplied.
  # Replace with the minimum permissions needed by your TFE workspaces.
  target_iam_policy = var.target_iam_policy_json != "" ? var.target_iam_policy_json : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOnlyDemo"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "s3:GetObject", "s3:ListBucket"]
        Resource = "*"
        # Replace with the minimum permissions needed by your TFE workspace.
      }
    ]
  })
}

# ─── Vault AWS Secrets Engine ────────────────────────────────────────────────
# Vault uses this backend to call STS on behalf of TFE workspaces.
# Provide access_key/secret_key for the IAM principal Vault authenticates as.
# If Vault happens to run on EC2 in the same AWS account, these can be omitted
# and Vault will fall back to the instance profile — but that is not required.

resource "vault_aws_secret_backend" "aws" {
  path        = var.aws_secrets_backend_path
  description = "AWS secrets engine — vault-backed dynamic credentials for TFE"
  region      = var.aws_secrets_backend_region

  access_key = var.vault_aws_access_key_id != "" ? var.vault_aws_access_key_id : null
  secret_key = var.vault_aws_secret_access_key != "" ? var.vault_aws_secret_access_key : null

  default_lease_ttl_seconds = var.default_sts_ttl_seconds
  max_lease_ttl_seconds     = var.max_sts_ttl_seconds
}

# ─── AWS Secrets Engine Role ─────────────────────────────────────────────────
# Defines how Vault generates credentials for this role.
# assumed_role: Vault calls sts:AssumeRole and returns scoped STS credentials.
# The effective permissions = intersection of the assumed role's policies
# and any session policy attached here.

resource "vault_aws_secret_backend_role" "tfe" {
  backend         = vault_aws_secret_backend.aws.path
  name            = var.aws_secrets_role_name
  credential_type = "assumed_role" # Vault assumes the IAM role below via STS

  role_arns = [aws_iam_role.vault_target.arn] # the role Vault will assume

  default_sts_ttl = var.default_sts_ttl_seconds
  max_sts_ttl     = var.max_sts_ttl_seconds
}

# ─── Vault Policy ────────────────────────────────────────────────────────────
# Grants the TFE JWT token permission to:
#   1. Manage its own token lifecycle (required by TFE dynamic creds protocol)
#   2. Read credentials from the AWS secrets engine role

resource "vault_policy" "tfe_backed_aws" {
  name = var.vault_policy_name

  policy = <<-EOT
    # Token self-management (required by TFE dynamic credentials protocol)
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }
    path "auth/token/revoke-self" {
      capabilities = ["update"]
    }

    # read triggers a credential generation; update allows TTL extension
    path "${var.aws_secrets_backend_path}/sts/${var.aws_secrets_role_name}" {
      capabilities = ["read", "update"]
    }

    # Allow TFE to read the backend configuration (metadata only)
    path "${var.aws_secrets_backend_path}/config/root" {
      capabilities = ["read"]
    }
  EOT
}

# ─── Vault JWT Auth Backend ──────────────────────────────────────────────────
# Vault trusts TFE's workload identity tokens via JWT auth. By default this
# module creates its own backend at "jwt-aws-provider", separate from
# dynamic_vault_secrets's default "jwt-vault-provider" backend.
# Set create_jwt_backend = false only when reusing an existing backend at the
# exact same path.

resource "vault_jwt_auth_backend" "tfe" {
  count = var.create_jwt_backend ? 1 : 0

  path        = var.jwt_backend_path
  description = "Workload identity JWT auth for TFE vault-backed AWS credentials"
  type        = "jwt"

  oidc_discovery_url    = "https://${var.tfe_hostname}" # TFE's OIDC discovery root
  bound_issuer          = "https://${var.tfe_hostname}" # must match 'iss' claim in TFE JWTs
  oidc_discovery_ca_pem = var.tfe_ca_cert_pem != "" ? var.tfe_ca_cert_pem : null
}

# ─── JWT Auth Role ───────────────────────────────────────────────────────────

resource "vault_jwt_auth_backend_role" "tfe" {
  # Use the path from the backend resource if it was created, otherwise use the variable directly.
  backend   = var.create_jwt_backend ? vault_jwt_auth_backend.tfe[0].path : var.jwt_backend_path
  role_name = var.vault_role_name
  role_type = "jwt"

  bound_audiences   = [var.workload_identity_audience]
  bound_claims_type = "glob" # enables wildcard matching for org/project/workspace

  # Scope this to a specific workspace in production instead of using wildcards.
  bound_claims = {
    sub = "organization:${var.tfe_organization}:project:${var.tfe_project}:workspace:${var.tfe_workspace}:run_phase:*"
  }

  user_claim = "terraform_full_workspace" # unique per workspace — appears in Vault audit logs

  token_policies = [vault_policy.tfe_backed_aws.name]
  token_ttl      = var.token_ttl_seconds
}

# ─── AWS IAM — Target Role ────────────────────────────────────────────────────
# Vault assumes this role to generate the STS credentials injected into TFE.
# The trust policy grants vault_iam_user_arn (the IAM principal Vault
# authenticates as — an IAM user or role) permission to assume this role.

resource "aws_iam_role" "vault_target" {
  name        = var.target_iam_role_name
  description = "Role assumed by Vault to generate dynamic credentials for TFE workspaces"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowVaultToAssume"
        Effect = "Allow"
        Principal = {
          AWS = var.vault_iam_user_arn
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    ManagedBy = "terraform"
    Module    = "dynamic_aws_provider_secrets"
  }
}

# Attaches the permissions TFE workspaces will receive via the assumed-role STS session.
resource "aws_iam_role_policy" "vault_target" {
  name   = "vault-dynamic-creds-permissions"
  role   = aws_iam_role.vault_target.id
  policy = local.target_iam_policy
}

# ─── TFE Workspace Variables ──────────────────────────────────────────────────
# Vault-backed AWS credential injection requires both the generic Vault auth
# vars and the AWS-specific vars below.
# If set_vault_auth_vars = false, another process must write the generic vars
# using this module's auth path and run role (jwt-aws-provider /
# tfe-vault-backed-aws) — do not reuse dynamic_vault_secrets's auth path/role.

resource "tfe_variable" "vault_provider_auth" {
  count = var.set_vault_auth_vars ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
  description  = "Enable Vault dynamic provider credentials"
}

resource "tfe_variable" "vault_addr" {
  count = var.set_vault_auth_vars ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_ADDR"
  value        = var.vault_addr
  category     = "env"
  description  = "Vault server address"
}

resource "tfe_variable" "vault_run_role" {
  count = var.set_vault_auth_vars ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_RUN_ROLE"
  value        = vault_jwt_auth_backend_role.tfe.role_name
  category     = "env"
  description  = "Vault JWT role for plan and apply"
}

resource "tfe_variable" "vault_auth_path" {
  count = var.set_vault_auth_vars ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_AUTH_PATH"
  value        = var.create_jwt_backend ? vault_jwt_auth_backend.tfe[0].path : var.jwt_backend_path
  category     = "env"
  description  = "Vault JWT auth backend path"
}

# Tells TFE to inject vault-backed AWS credentials into the workspace environment.
resource "tfe_variable" "vault_backed_aws_auth" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_AUTH"
  value        = "true"
  category     = "env"
  description  = "Enable vault-backed AWS dynamic credentials"
}

# The Vault AWS secrets engine role name — Vault uses this to look up which
# IAM role to assume when generating credentials.
resource "tfe_variable" "vault_backed_aws_run_vault_role" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_RUN_VAULT_ROLE"
  value        = vault_aws_secret_backend_role.tfe.name
  category     = "env"
  description  = "Vault AWS secrets engine role name"
}

# IAM role ARN that Vault assumes (via STS) when credential_type = assumed_role.
resource "tfe_variable" "vault_backed_aws_run_role_arn" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_RUN_ROLE_ARN"
  value        = aws_iam_role.vault_target.arn
  category     = "env"
  description  = "ARN of the IAM role Vault assumes to generate STS credentials"
}

resource "tfe_variable" "vault_backed_aws_mount" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_MOUNT_PATH"
  value        = vault_aws_secret_backend.aws.path
  category     = "env"
  description  = "Mount path of the Vault AWS secrets engine"
}

# Must match the credential_type set on vault_aws_secret_backend_role above.
resource "tfe_variable" "vault_backed_aws_auth_type" {
  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_AUTH_TYPE"
  value        = "assumed_role"
  category     = "env"
  description  = "AWS credential type — must match vault_aws_secret_backend_role credential_type"
}

resource "tfe_variable" "vault_encoded_cacert" {
  # Only inject when a CA cert is provided and not delegated to dynamic_vault_secrets.
  count = var.set_vault_auth_vars && var.vault_ca_cert_b64 != "" ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
  description  = "Base64-encoded Vault CA cert (self-signed TLS)"
}
