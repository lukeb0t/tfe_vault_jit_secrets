# ─── Test: Dynamic Provider Credentials (Vault KV) ───────────────────────────
# This workspace is configured with TFC_VAULT_PROVIDER_AUTH=true and the
# jwt-vault-provider backend. TFE exchanges a workload identity JWT for a
# short-lived Vault token, which is injected into the Vault provider below.
#
# Expected result: plan succeeds and outputs the keys of the demo/app KV secret.

terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# TFE injects VAULT_TOKEN via TFC_VAULT_PROVIDER_AUTH — no static credentials needed.
provider "vault" {}

data "vault_kv_secret_v2" "demo" {
  mount = "kv"
  name  = "demo/app"
}

output "secret_keys" {
  description = "Keys present in the demo KV secret (values omitted — proves Vault auth succeeded)"
  value       = keys(data.vault_kv_secret_v2.demo.data)
  sensitive   = true
}
