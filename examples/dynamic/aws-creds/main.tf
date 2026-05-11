# ─── Vault JWT Auth + AWS Secrets Engine ─────────────────────────────────────
# Configures a Vault JWT auth backend and AWS secrets engine so TFE can exchange
# a short-lived workload identity JWT for temporary AWS STS credentials via Vault.
module "dynamic_aws_provider_secrets" {
  source = "../../../dynamic_aws_provider_secrets"

  vault_addr                  = var.vault_addr
  vault_token                 = var.vault_root_token
  tfe_hostname                = var.tfe_hostname
  tfe_organization            = var.tfe_org_name
  tfe_project                 = "*"
  tfe_workspace               = "*"
  aws_secrets_backend_region  = var.aws_region
  vault_iam_user_arn          = local.vault_iam_principal_arn_effective
  vault_aws_access_key_id     = var.vault_aws_access_key_id
  vault_aws_secret_access_key = var.vault_aws_secret_access_key

  tfe_workspace_id    = tfe_workspace.aws_test.id
  tfe_token           = var.tfe_org_token
  vault_ca_cert_b64   = var.vault_ca_cert_b64
  tfe_ca_cert_pem     = var.tfe_ca_cert_pem
  set_vault_auth_vars = true
}

locals {
  vault_iam_principal_arn_effective = var.vault_iam_principal_arn != "" ? var.vault_iam_principal_arn : var.vault_iam_role_arn
}

# ─── Test Workspace: aws-creds-test ──────────────────────────────────────────
# TFE authenticates to Vault at jwt-aws-provider, exchanges the JWT for STS
# credentials, and uses them to call AWS APIs (e.g. list AZs).
resource "tfe_workspace" "aws_test" {
  name         = "aws-creds-test"
  organization = var.tfe_org_name
  auto_apply   = true
  force_delete = true
  description  = "Test: vault-backed AWS dynamic creds — lists AZs via STS credentials"
}

# ── Vault auth vars (required for vault-backed AWS flow) ─────────────────────
resource "tfe_variable" "vault_provider_auth" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
}

resource "tfe_variable" "vault_addr" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_ADDR"
  value        = var.vault_addr
  category     = "env"
}

resource "tfe_variable" "vault_auth_path" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_AUTH_PATH"
  value        = module.dynamic_aws_provider_secrets.jwt_backend_path
  category     = "env"
}

resource "tfe_variable" "vault_run_role" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_RUN_ROLE"
  value        = module.dynamic_aws_provider_secrets.vault_role_name
  category     = "env"
}

resource "tfe_variable" "vault_cacert" {
  count        = var.vault_ca_cert_b64 != "" ? 1 : 0
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
}

# ── Vault-backed AWS vars ─────────────────────────────────────────────────────
resource "tfe_variable" "backed_aws_auth" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_AUTH"
  value        = "true"
  category     = "env"
}

resource "tfe_variable" "backed_aws_auth_path" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_AUTH_PATH"
  value        = module.dynamic_aws_provider_secrets.jwt_backend_path
  category     = "env"
}

resource "tfe_variable" "backed_aws_auth_type" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_AUTH_TYPE"
  value        = "assumed_role"
  category     = "env"
}

resource "tfe_variable" "backed_aws_run_vault_role" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_RUN_VAULT_ROLE"
  value        = module.dynamic_aws_provider_secrets.aws_secrets_role_name
  category     = "env"
}

resource "tfe_variable" "backed_aws_mount" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_MOUNT_PATH"
  value        = module.dynamic_aws_provider_secrets.aws_secrets_backend_path
  category     = "env"
}

resource "tfe_variable" "backed_aws_run_role_arn" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_RUN_ROLE_ARN"
  value        = module.dynamic_aws_provider_secrets.target_iam_role_arn
  category     = "env"
}

# ─── Test Config Upload ───────────────────────────────────────────────────────
locals {
  test_config = "${path.module}/test/aws-creds-test/main.tf"
}

resource "tfe_team" "config_upload" {
  name         = "aws-creds-config-upload"
  organization = var.tfe_org_name

  organization_access {
    manage_workspaces = true
  }
}

resource "tfe_team_token" "upload" {
  team_id = tfe_team.config_upload.id
}

resource "null_resource" "upload_config" {
  triggers = {
    config_hash = filesha256(local.test_config)
    workspace   = tfe_workspace.aws_test.id
  }

  provisioner "local-exec" {
    command     = <<-EOF
      set -e
      WORK=$(mktemp -d)
      cp "${local.test_config}" "$WORK/"
      tar -czf "$WORK/config.tar.gz" -C "$WORK" main.tf

      CV=$(curl -sf -k \
        -H "Authorization: Bearer ${tfe_team_token.upload.token}" \
        -H "Content-Type: application/vnd.api+json" \
        "https://${var.tfe_hostname}/api/v2/workspaces/${tfe_workspace.aws_test.id}/configuration-versions" \
        -d '{"data":{"type":"configuration-versions","attributes":{"auto-queue-runs":false}}}')

      UPLOAD_URL=$(echo "$CV" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['attributes']['upload-url'])")

      curl -sf -k \
        -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$WORK/config.tar.gz" \
        "$UPLOAD_URL"

      rm -rf "$WORK"
      echo "aws-creds-test config uploaded"
    EOF
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    tfe_workspace.aws_test,
    tfe_variable.vault_provider_auth,
    tfe_variable.vault_addr,
    tfe_variable.vault_auth_path,
    tfe_variable.vault_run_role,
    tfe_variable.vault_cacert,
    tfe_variable.backed_aws_auth,
    tfe_variable.backed_aws_auth_path,
    tfe_variable.backed_aws_auth_type,
    tfe_variable.backed_aws_run_vault_role,
    tfe_variable.backed_aws_mount,
    tfe_variable.backed_aws_run_role_arn,
  ]
}
