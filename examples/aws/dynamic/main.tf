# ─── TFE Workspace ──────────────────────────────────────────────────────────
# Create a demo workspace that shows module-driven variable injection.
# Use the dedicated test workspaces below for end-to-end runs of each flow.
resource "tfe_workspace" "demo" {
  name         = "vault-dynamic-creds-demo"
  organization = var.tfe_org_name
  auto_apply   = false  # require manual approval for safety
  description  = "Demo workspace showing Vault dynamic credential variables"
}

# ─── Use Case 1: Dynamic Provider Credentials ───────────────────────────────
# Configures Vault JWT auth so TFE can authenticate to Vault and use it
# as a credential provider (e.g., reading KV secrets during plan/apply).
module "dynamic_vault_secrets" {
  source = "../../../dynamic_vault_secrets"

  vault_addr       = var.vault_addr
  tfe_hostname     = var.tfe_hostname
  tfe_organization = var.tfe_org_name
  tfe_project      = "*"
  tfe_workspace    = "*"

  configure_tfe_workspace = true
  tfe_workspace_id        = tfe_workspace.demo.id
  vault_ca_cert_b64       = var.vault_ca_cert_b64
  tfe_ca_cert_pem         = var.tfe_ca_cert_pem
  create_demo_kv_mount    = true
  secret_paths            = ["kv/data/*"]
}

# ─── Use Case 2: Vault-backed AWS Dynamic Secrets ───────────────────────────
# Configures Vault AWS secrets engine so TFE can obtain short-lived AWS
# credentials via Vault rather than using static IAM keys.
# This module creates its own JWT backend at "jwt-aws-provider" by default,
# independent from dynamic_vault_secrets's "jwt-vault-provider" backend.
module "dynamic_aws_provider_secrets" {
  source = "../../../dynamic_aws_provider_secrets"

  vault_addr                 = var.vault_addr
  tfe_hostname               = var.tfe_hostname
  tfe_organization           = var.tfe_org_name
  tfe_project                = "*"
  tfe_workspace              = "*"
  aws_secrets_backend_region = var.aws_region
  vault_iam_user_arn         = var.vault_iam_role_arn

  configure_tfe_workspace = true
  tfe_workspace_id        = tfe_workspace.demo.id
  vault_ca_cert_b64       = var.vault_ca_cert_b64
  tfe_ca_cert_pem         = var.tfe_ca_cert_pem
  # The demo workspace above is only a combined-variable example; the dedicated
  # aws_test workspace below sets the AWS flow's auth path and run role explicitly.
  set_vault_auth_vars = false
}

# ─── KV Test Data ─────────────────────────────────────────────────────────────
resource "vault_kv_secret_v2" "demo_app" {
  mount               = module.dynamic_vault_secrets.kv_mount_path
  name                = "demo/app"
  delete_all_versions = true

  data_json = jsonencode({
    db_username = "demo-user"
    db_password = "s3cr3t-demo-password"
    api_key     = "demo-api-key-12345"
  })

  depends_on = [module.dynamic_vault_secrets]
}

# ─── Test Workspace 1: vault-kv-test ─────────────────────────────────────────
# Isolated workspace to verify the dynamic_vault_secrets flow end-to-end.
# TFE authenticates to Vault at jwt-vault-provider, gets a Vault token,
# and uses it to read a KV secret via the Vault Terraform provider.
resource "tfe_workspace" "kv_test" {
  name         = "vault-kv-test"
  organization = var.tfe_org_name
  auto_apply   = true
  description  = "Test: vault provider dynamic creds — reads KV secret from Vault"
}

resource "tfe_variable" "kv_test_vault_auth" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
}

resource "tfe_variable" "kv_test_vault_addr" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_ADDR"
  value        = var.vault_addr
  category     = "env"
}

resource "tfe_variable" "kv_test_vault_role" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_RUN_ROLE"
  value        = module.dynamic_vault_secrets.vault_role_name
  category     = "env"
}

resource "tfe_variable" "kv_test_vault_auth_path" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_AUTH_PATH"
  value        = module.dynamic_vault_secrets.jwt_backend_path
  category     = "env"
}

resource "tfe_variable" "kv_test_vault_cacert" {
  count        = var.vault_ca_cert_b64 != "" ? 1 : 0
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
}

# ─── Test Workspace 2: aws-creds-test ────────────────────────────────────────
# Isolated workspace to verify the dynamic_aws_provider_secrets flow end-to-end.
# TFE authenticates to Vault at jwt-aws-provider, gets an STS credential
# from the Vault AWS secrets engine, and uses it to call AWS APIs.
resource "tfe_workspace" "aws_test" {
  name         = "aws-creds-test"
  organization = var.tfe_org_name
  auto_apply   = true
  description  = "Test: vault-backed AWS dynamic creds — lists AZs via STS credentials"
}

# ── Vault auth vars (required even for vault-backed AWS flow) ─────────────────
resource "tfe_variable" "aws_test_vault_provider_auth" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
}

resource "tfe_variable" "aws_test_vault_addr" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_ADDR"
  value        = var.vault_addr
  category     = "env"
}

resource "tfe_variable" "aws_test_vault_auth_path" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_AUTH_PATH"
  value        = module.dynamic_aws_provider_secrets.jwt_backend_path
  category     = "env"
}

resource "tfe_variable" "aws_test_vault_run_role" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_RUN_ROLE"
  value        = module.dynamic_aws_provider_secrets.vault_role_name
  category     = "env"
}

resource "tfe_variable" "aws_test_vault_cacert" {
  count        = var.vault_ca_cert_b64 != "" ? 1 : 0
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
}

# ── Vault-backed AWS vars ─────────────────────────────────────────────────────
resource "tfe_variable" "aws_test_backed_aws_auth" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_AUTH"
  value        = "true"
  category     = "env"
}

resource "tfe_variable" "aws_test_backed_aws_auth_type" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_AUTH_TYPE"
  value        = "assumed_role"
  category     = "env"
}

resource "tfe_variable" "aws_test_backed_aws_run_vault_role" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_RUN_VAULT_ROLE"
  value        = module.dynamic_aws_provider_secrets.aws_secrets_role_name
  category     = "env"
}

resource "tfe_variable" "aws_test_backed_aws_mount" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_MOUNT_PATH"
  value        = module.dynamic_aws_provider_secrets.aws_secrets_backend_path
  category     = "env"
}

resource "tfe_variable" "aws_test_backed_aws_run_role_arn" {
  workspace_id = tfe_workspace.aws_test.id
  key          = "TFC_VAULT_BACKED_AWS_RUN_ROLE_ARN"
  value        = module.dynamic_aws_provider_secrets.target_iam_role_arn
  category     = "env"
}

# ─── Test Config Upload ───────────────────────────────────────────────────────
# Packages each test directory and pushes it to the corresponding TFE workspace
# as a configuration version. Runs are triggered manually via the TFE UI.
# Re-uploads automatically when the config files change (hash-based trigger).
#
# Uses a short-lived owners team token (created inline) because the org token
# lacks workspace write access required to POST configuration versions.

locals {
  test_dir = "${path.module}/test"
}

resource "tfe_team" "config_upload" {
  name         = "test-config-upload"
  organization = var.tfe_org_name

  organization_access {
    manage_workspaces = true
  }
}

resource "tfe_team_token" "upload" {
  team_id = tfe_team.config_upload.id
}

resource "null_resource" "upload_kv_test_config" {
  triggers = {
    config_hash = filesha256("${local.test_dir}/vault-kv-test/main.tf")
    workspace   = tfe_workspace.kv_test.id
  }

  provisioner "local-exec" {
    command = <<-EOF
      set -e
      WORK=$(mktemp -d)
      cp "${local.test_dir}/vault-kv-test/main.tf" "$WORK/"
      tar -czf "$WORK/config.tar.gz" -C "$WORK" main.tf

      CV=$(curl -sf -k \
        -H "Authorization: Bearer ${tfe_team_token.upload.token}" \
        -H "Content-Type: application/vnd.api+json" \
        "https://${var.tfe_hostname}/api/v2/workspaces/${tfe_workspace.kv_test.id}/configuration-versions" \
        -d '{"data":{"type":"configuration-versions","attributes":{"auto-queue-runs":false}}}')

      UPLOAD_URL=$(echo "$CV" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['attributes']['upload-url'])")

      curl -sf -k \
        -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$WORK/config.tar.gz" \
        "$UPLOAD_URL"

      rm -rf "$WORK"
      echo "vault-kv-test config uploaded"
    EOF
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    tfe_workspace.kv_test,
    tfe_variable.kv_test_vault_auth,
    tfe_variable.kv_test_vault_addr,
    tfe_variable.kv_test_vault_role,
    tfe_variable.kv_test_vault_auth_path,
    tfe_variable.kv_test_vault_cacert,
  ]
}

resource "null_resource" "upload_aws_test_config" {
  triggers = {
    config_hash = filesha256("${local.test_dir}/aws-creds-test/main.tf")
    workspace   = tfe_workspace.aws_test.id
  }

  provisioner "local-exec" {
    command = <<-EOF
      set -e
      WORK=$(mktemp -d)
      cp "${local.test_dir}/aws-creds-test/main.tf" "$WORK/"
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
    tfe_variable.aws_test_vault_provider_auth,
    tfe_variable.aws_test_vault_addr,
    tfe_variable.aws_test_vault_auth_path,
    tfe_variable.aws_test_vault_run_role,
    tfe_variable.aws_test_vault_cacert,
    tfe_variable.aws_test_backed_aws_auth,
    tfe_variable.aws_test_backed_aws_auth_type,
    tfe_variable.aws_test_backed_aws_run_vault_role,
    tfe_variable.aws_test_backed_aws_mount,
    tfe_variable.aws_test_backed_aws_run_role_arn,
  ]
}
