# =============================================================================
# dynamic_vault_secrets
#
# Configures Vault-backed dynamic AWS credentials for Terraform Enterprise.
# TFE workspaces authenticate to Vault via JWT workload identity, receive a
# short-lived Vault token, and then Vault directly injects STS credentials
# into the workspace environment — no static AWS credentials required.
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
  # Use a read-only demo policy when no custom policy is supplied
  target_iam_policy = var.target_iam_policy_json != "" ? var.target_iam_policy_json : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOnlyDemo"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "s3:GetObject", "s3:ListBucket"]
        Resource = "*"
        Comment  = "Replace with the minimum permissions needed by your TFE workspace."
      }
    ]
  })
}

# ─── Vault AWS Secrets Engine ────────────────────────────────────────────────
# Vault uses these static IAM user credentials to call STS and assume the
# target IAM role.  Leave access_key/secret_key empty to inherit credentials
# from the Vault EC2 instance profile instead.

resource "vault_aws_secret_backend" "aws" {
  path        = var.aws_secrets_backend_path
  description = "AWS secrets engine — vault-backed dynamic credentials for TFE"
  region      = var.aws_secrets_backend_region

  # Static IAM user credentials for Vault's AWS access.
  # Omit if Vault runs on EC2 with an instance profile that can call sts:AssumeRole.
  access_key = var.vault_aws_access_key_id != "" ? var.vault_aws_access_key_id : null
  secret_key = var.vault_aws_secret_access_key != "" ? var.vault_aws_secret_access_key : null

  default_ttl = var.default_sts_ttl_seconds
  max_ttl     = var.max_sts_ttl_seconds
}

# ─── AWS Secrets Engine Role ─────────────────────────────────────────────────
# Using assumed_role credential type: Vault assumes the target IAM role and
# returns scoped STS credentials.  The effective permissions are the
# intersection of the assumed role's policies and any session policy defined
# here.

resource "vault_aws_secret_backend_role" "tfe" {
  backend         = vault_aws_secret_backend.aws.path
  name            = var.aws_secrets_role_name
  credential_type = "assumed_role"

  role_arns = [aws_iam_role.vault_target.arn]

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

    # Allow TFE to generate AWS STS credentials from the secrets engine role
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

resource "vault_jwt_auth_backend" "tfe" {
  path        = var.jwt_backend_path
  description = "Workload identity JWT auth for TFE vault-backed AWS credentials"
  type        = "jwt"

  oidc_discovery_url = "https://${var.tfe_hostname}"
  bound_issuer       = "https://${var.tfe_hostname}"

  # Uncomment if TFE uses a private/self-signed certificate:
  # oidc_discovery_ca_pem = file("tfe-ca.pem")
}

# ─── JWT Auth Role ───────────────────────────────────────────────────────────

resource "vault_jwt_auth_backend_role" "tfe" {
  backend   = vault_jwt_auth_backend.tfe.path
  role_name = var.vault_role_name
  role_type = "jwt"

  bound_audiences   = [var.workload_identity_audience]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfe_organization}:project:${var.tfe_project}:workspace:${var.tfe_workspace}:run_phase:*"
  }

  user_claim = "terraform_full_workspace"

  token_policies  = [vault_policy.tfe_backed_aws.name]
  token_ttl       = var.token_ttl_seconds
  token_renewable = true
}

# ─── AWS IAM — Target Role ────────────────────────────────────────────────────
# Vault assumes this role to generate the STS credentials injected into TFE.
# The trust policy allows the Vault IAM principal (user or EC2 role) to assume it.

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
    Module    = "dynamic_vault_secrets"
  }
}

resource "aws_iam_role_policy" "vault_target" {
  name   = "vault-dynamic-creds-permissions"
  role   = aws_iam_role.vault_target.id
  policy = local.target_iam_policy
}

# ─── TFE Workspace Variables ──────────────────────────────────────────────────
# Vault-backed AWS credential injection requires these env vars in the workspace.
# The Vault provider auth variables (TFC_VAULT_PROVIDER_AUTH, TFC_VAULT_ADDR,
# TFC_VAULT_RUN_ROLE) are also required — either set them here or use the
# dynamic_provider_cred module alongside this one.
#
# Un-comment the tfe provider in versions.tf and set configure_tfe_workspace = true.

resource "tfe_variable" "vault_provider_auth" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
  description  = "Enable Vault dynamic provider credentials"
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
  value        = vault_jwt_auth_backend_role.tfe.role_name
  category     = "env"
  description  = "Vault JWT role for plan and apply"
}

# Tells TFE to inject vault-backed AWS credentials into the workspace
resource "tfe_variable" "vault_backed_aws_auth" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_AUTH"
  value        = "true"
  category     = "env"
  description  = "Enable vault-backed AWS dynamic credentials"
}

resource "tfe_variable" "vault_backed_aws_role" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_RUN_ROLE"
  value        = vault_jwt_auth_backend_role.tfe.role_name
  category     = "env"
  description  = "Vault role used to generate AWS STS credentials"
}

resource "tfe_variable" "vault_backed_aws_secrets_role" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_ROLE"
  value        = vault_aws_secret_backend_role.tfe.name
  category     = "env"
  description  = "Vault AWS secrets engine role name"
}

resource "tfe_variable" "vault_backed_aws_mount" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_MOUNT_PATH"
  value        = vault_aws_secret_backend.aws.path
  category     = "env"
  description  = "Mount path of the Vault AWS secrets engine"
}

resource "tfe_variable" "vault_backed_aws_auth_type" {
  count = var.configure_tfe_workspace ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_BACKED_AWS_AUTH_TYPE"
  value        = "assumed_role"
  category     = "env"
  description  = "AWS credential type — must match vault_aws_secret_backend_role credential_type"
}

resource "tfe_variable" "vault_encoded_cacert" {
  count = var.configure_tfe_workspace && var.vault_ca_cert_b64 != "" ? 1 : 0

  workspace_id = var.tfe_workspace_id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
  description  = "Base64-encoded Vault CA cert (self-signed TLS)"
}
