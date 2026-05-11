# ─── Vault JWT Auth Backend ──────────────────────────────────────────────────
# Configures a JWT auth backend in Vault that trusts TFE workload identity
# tokens. TFE workspaces exchange a JWT for a short-lived Vault token, which
# is injected as VAULT_TOKEN for use with the Vault Terraform provider.
module "dynamic_vault_secrets" {
  source = "../../../dynamic_vault_secrets"

  vault_addr       = var.vault_addr
  vault_token      = var.vault_root_token
  tfe_hostname     = var.tfe_hostname
  tfe_organization = var.tfe_org_name
  tfe_project      = "*"
  tfe_workspace    = "*"

  tfe_workspace_id     = tfe_workspace.kv_test.id
  tfe_token            = var.tfe_org_token
  vault_ca_cert_b64    = var.vault_ca_cert_b64
  tfe_ca_cert_pem      = var.tfe_ca_cert_pem
  create_demo_kv_mount = true
  secret_paths         = ["kv/data/*"]
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

# ─── Test Workspace: vault-kv-test ───────────────────────────────────────────
# TFE authenticates to Vault at jwt-vault-provider, receives a short-lived
# Vault token, and uses it to read a KV secret via the Vault Terraform provider.
resource "tfe_workspace" "kv_test" {
  name         = "vault-kv-test"
  organization = var.tfe_org_name
  auto_apply   = true
  force_delete = true
  description  = "Test: vault provider dynamic creds — reads KV secret from Vault"
}

resource "tfe_variable" "vault_provider_auth" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
}

resource "tfe_variable" "vault_addr" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_ADDR"
  value        = var.vault_addr
  category     = "env"
}

resource "tfe_variable" "vault_run_role" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_RUN_ROLE"
  value        = module.dynamic_vault_secrets.vault_role_name
  category     = "env"
}

resource "tfe_variable" "vault_auth_path" {
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_AUTH_PATH"
  value        = module.dynamic_vault_secrets.jwt_backend_path
  category     = "env"
}

resource "tfe_variable" "vault_cacert" {
  count        = var.vault_ca_cert_b64 != "" ? 1 : 0
  workspace_id = tfe_workspace.kv_test.id
  key          = "TFC_VAULT_ENCODED_CACERT"
  value        = var.vault_ca_cert_b64
  category     = "env"
  sensitive    = true
}

# ─── Test Config Upload ───────────────────────────────────────────────────────
locals {
  test_config = "${path.module}/test/vault-kv-test/main.tf"
}

resource "tfe_team" "config_upload" {
  name         = "vault-provider-config-upload"
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
    workspace   = tfe_workspace.kv_test.id
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
    tfe_variable.vault_provider_auth,
    tfe_variable.vault_addr,
    tfe_variable.vault_run_role,
    tfe_variable.vault_auth_path,
    tfe_variable.vault_cacert,
  ]
}
