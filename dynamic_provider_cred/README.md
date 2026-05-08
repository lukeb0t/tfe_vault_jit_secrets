# dynamic_provider_cred

Terraform module that configures **Vault JWT auth to trust workload identity tokens issued by Terraform Enterprise (TFE)**. TFE workspaces exchange a workload-identity JWT for a short-lived Vault token scoped to a Vault policy — enabling the Vault Terraform provider to authenticate without a long-lived token.

**Reference:** [Dynamic Provider Credentials — Vault configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration)

## How it works

```
TFE workspace run
      │
      │  1. TFE mints a workload-identity JWT
      │     (aud = "vault.workload.identity")
      │     (sub = "organization:<org>:project:<proj>:workspace:<ws>:run_phase:<phase>")
      ▼
Vault JWT auth backend  (default mount: jwt-vault-provider/)
      │
      │  2. Vault validates JWT signature via TFE's OIDC discovery URL
      │  3. Vault checks bound_claims (org / project / workspace)
      │  4. Vault issues a short-lived token with the attached policy
      ▼
Vault token  (TTL = 20 min, renewable)
      │
      │  5. TFE injects token as VAULT_TOKEN in the workspace environment
      ▼
Vault Terraform provider  (reads secrets, manages Vault resources)
```

## Usage

### Minimal

```hcl
provider "vault" {
  address = "https://vault.example.com:8200"
  token   = var.vault_root_token   # bootstrap only
}

module "dyn_provider" {
  source = "./dynamic_provider_cred"

  vault_addr       = "https://vault.example.com:8200"
  tfe_hostname     = "tfe.example.com"
  tfe_organization = "my-org"
}
```

### Scoped to a specific workspace

```hcl
module "dyn_provider" {
  source = "./dynamic_provider_cred"

  vault_addr       = "https://vault.example.com:8200"
  tfe_hostname     = "tfe.example.com"
  tfe_organization = "my-org"
  tfe_project      = "platform"
  tfe_workspace    = "infra-prod"

  secret_paths = [
    "kv/data/infra-prod/*",
    "kv/data/shared/*",
  ]
}
```

### With automatic TFE workspace variable injection

```hcl
module "dyn_provider" {
  source = "./dynamic_provider_cred"

  vault_addr       = "https://vault.example.com:8200"
  tfe_hostname     = "tfe.example.com"
  tfe_organization = "my-org"
  tfe_workspace    = "my-workspace"

  configure_tfe_workspace = true
  tfe_workspace_id        = "ws-XXXXXXXXXXXXXXXX"

  # For self-signed Vault TLS — base64 encode the PEM cert:
  # vault_ca_cert_b64 = base64encode(file("vault-ca.pem"))
}
```

> **Provider requirement:** Set `configure_tfe_workspace = true` only after uncommenting the `tfe` provider in `versions.tf` and providing a TFE token.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| hashicorp/vault | ~> 4.0 |
| hashicorp/tfe | ~> 0.57 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `vault_addr` | Address of the Vault server (e.g. `https://1.2.3.4:8200`). | `string` | — | ✅ |
| `tfe_hostname` | Hostname of the self-hosted TFE instance (e.g. `tfe.example.com`). Used as OIDC discovery URL and `bound_issuer`. | `string` | — | ✅ |
| `tfe_organization` | TFE organization name. Scopes `bound_claims` to this org. | `string` | — | ✅ |
| `vault_namespace` | Vault namespace. Leave empty for root namespace. | `string` | `""` | |
| `tfe_project` | TFE project name. Use `"*"` to match all projects. | `string` | `"*"` | |
| `tfe_workspace` | TFE workspace name. Use `"*"` to match all workspaces. | `string` | `"*"` | |
| `jwt_backend_path` | Mount path for the JWT auth backend. | `string` | `"jwt-vault-provider"` | |
| `vault_role_name` | Name of the Vault JWT auth role. | `string` | `"tfe-dynamic-creds"` | |
| `vault_policy_name` | Name of the Vault policy attached to the role. | `string` | `"tfe-dynamic-creds-policy"` | |
| `workload_identity_audience` | Expected `aud` claim in TFE JWT tokens. Must match `TFC_VAULT_WORKLOAD_IDENTITY_AUDIENCE` if overridden. | `string` | `"vault.workload.identity"` | |
| `token_ttl_seconds` | Lifetime of Vault tokens issued to TFE. TFE renews periodically during long runs. | `number` | `1200` | |
| `secret_paths` | Vault paths the policy grants `read` access to. | `list(string)` | `["kv/data/*"]` | |
| `create_demo_kv_mount` | Create a KV v2 mount at `kv/` as a demonstration target. | `bool` | `true` | |
| `configure_tfe_workspace` | Automatically create `tfe_variable` resources in the target workspace. Requires `tfe` provider. | `bool` | `false` | |
| `tfe_workspace_id` | TFE workspace ID (e.g. `ws-XXXXXXXXXXXXXXXX`). Required when `configure_tfe_workspace = true`. | `string` | `""` | |
| `vault_ca_cert_b64` | Base64-encoded PEM CA certificate for Vault. Injected as `TFC_VAULT_ENCODED_CACERT`. Required for self-signed TLS. | `string` (sensitive) | `""` | |

## Outputs

| Name | Description |
|------|-------------|
| `jwt_backend_path` | Mount path of the Vault JWT auth backend. |
| `jwt_backend_accessor` | Accessor of the JWT auth backend. |
| `vault_role_name` | Name of the Vault JWT auth role. |
| `vault_policy_name` | Name of the Vault policy. |
| `kv_mount_path` | Mount path of the demo KV v2 mount (`null` if `create_demo_kv_mount = false`). |
| `tfe_workspace_env_vars` | Map of the non-sensitive core environment variables for the TFE workspace. Add `TFC_VAULT_ENCODED_CACERT` separately when Vault uses self-signed TLS. |

## TFE workspace environment variables

When `configure_tfe_workspace = false` (the default), set these variables manually in the TFE workspace:

| Variable | Value | Notes |
|----------|-------|-------|
| `TFC_VAULT_PROVIDER_AUTH` | `true` | Enables dynamic Vault credentials |
| `TFC_VAULT_ADDR` | `https://vault.example.com:8200` | Must be reachable from TFE agents |
| `TFC_VAULT_RUN_ROLE` | `tfe-dynamic-creds` | Must match `vault_role_name` |
| `TFC_VAULT_NAMESPACE` | `""` | Omit for root namespace |
| `TFC_VAULT_AUTH_PATH` | `jwt-vault-provider` | Must match `jwt_backend_path` |
| `TFC_VAULT_ENCODED_CACERT` | `<base64 PEM>` | Required for self-signed TLS (**sensitive**) |

The non-sensitive subset is also available as the `tfe_workspace_env_vars` output for scripting. Add `TFC_VAULT_ENCODED_CACERT` separately when Vault uses self-signed TLS.

## What Vault resources are created

| Resource | Name/Path |
|----------|-----------|
| JWT auth backend | `auth/<jwt_backend_path>` |
| JWT auth role | `<jwt_backend_path>/role/<vault_role_name>` |
| Vault policy | `<vault_policy_name>` |
| KV v2 mount (optional) | `kv/` |

In `examples/aws/dynamic`, the `vault-kv-test` workspace uses this flow to read `kv/data/demo/app`.

## References

- [TFE Dynamic Provider Credentials — overview](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials)
- [TFE Dynamic Provider Credentials — Vault configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration)
- [Vault JWT/OIDC auth method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Vault JWT auth — bound_claims](https://developer.hashicorp.com/vault/api-docs/auth/jwt#bound_claims)
- [TFE workload identity tokens](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials/workload-identity-tokens)
- [hashicorp/vault Terraform provider](https://registry.terraform.io/providers/hashicorp/vault/latest/docs)
- [hashicorp/tfe Terraform provider](https://registry.terraform.io/providers/hashicorp/tfe/latest/docs)
