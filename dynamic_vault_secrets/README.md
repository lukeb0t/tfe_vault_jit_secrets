# dynamic_vault_secrets

Terraform module that configures **Vault-backed dynamic AWS credentials for Terraform Enterprise**. TFE workspaces authenticate to Vault via JWT workload identity; Vault then generates short-lived AWS STS credentials via the AWS secrets engine, and TFE injects them into the workspace environment. No static AWS access keys are stored anywhere.

**Reference:** [Terraform Vault-backed dynamic credentials for AWS](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws)

## How it works

```
TFE workspace run
      │
      │  1. TFE mints a workload-identity JWT
      ▼
Vault JWT auth backend  (default mount: jwt-aws-provider/)
      │
      │  2. Vault validates JWT, issues a short-lived Vault token
      ▼
Vault AWS secrets engine  (assumed_role credential type)
      │
      │  3. Vault calls sts:AssumeRole using the EC2 instance profile
      │  4. Vault returns short-lived STS credentials
      ▼
TFE workspace environment
      │  AWS_ACCESS_KEY_ID       ← injected by TFE dynamic credentials
      │  AWS_SECRET_ACCESS_KEY   ← injected by TFE dynamic credentials
      │  AWS_SESSION_TOKEN       ← injected by TFE dynamic credentials
      ▼
AWS Terraform provider  (no static credentials required)
```

**Credential chain:** Vault's EC2 instance profile → `sts:AssumeRole` → target IAM role → scoped STS session. The effective permissions are the intersection of the target role's policies and any inline session policy.

## Usage

This module ships with `providers.tf` pre-configured for **standalone use**. Copy `terraform.tfvars.example` to `terraform.tfvars`, fill in your values, then:

```sh
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform apply
```

### Minimal `terraform.tfvars`

```hcl
vault_addr  = "https://vault.example.com:8200"
vault_token = "hvs.XXXXXXXX"   # bootstrap token; rotate after first apply

# Works with any TFE instance — self-hosted via tfe_deploy_aws or bring-your-own.
tfe_hostname     = "tfe.example.com"
tfe_organization = "my-org"

aws_secrets_backend_region = "us-east-1"

# ARN of the Vault EC2 instance role — allows Vault to call sts:AssumeRole.
# When using alongside vault_deploy_aws, use: module.vault.iam_role_arn
vault_iam_user_arn = "arn:aws:iam::123456789012:role/my-vault-server"
```

### With custom IAM permissions for the target role

```hcl
target_iam_role_name = "tfe-infra-prod-role"

target_iam_policy_json = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect   = "Allow"
    Action   = ["ec2:*", "s3:*"]
    Resource = "*"
  }]
})
```

### With automatic TFE workspace variable injection

Set `configure_tfe_workspace = true` to have Terraform inject the required `TFC_VAULT_*` and `TFC_VAULT_BACKED_AWS_*` environment variables into the workspace automatically. Requires a TFE token with workspace-write permissions.

```hcl
configure_tfe_workspace = true
tfe_workspace_id        = "ws-XXXXXXXXXXXXXXXX"
tfe_token               = "TOKEN"   # org token or team token with manage_workspaces
vault_ca_cert_b64       = base64encode(file("vault-ca.pem"))
```

See [TFE workspace environment variables](#tfe-workspace-environment-variables) for the manual equivalent.

### Using as a child module

When calling this module from another root module (rather than running it standalone), remove `providers.tf` from this directory and configure the `vault`, `aws`, and `tfe` providers in the calling root module instead.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| hashicorp/aws | ~> 5.0 |
| hashicorp/vault | ~> 4.0 |
| hashicorp/tfe | ~> 0.57 |

### AWS permissions required by the caller

To create the target IAM role, the Terraform principal needs:

- `iam:CreateRole`, `iam:PutRolePolicy`, `iam:DeleteRole`, `iam:DeleteRolePolicy`

### AWS permissions required by the Vault EC2 role

The Vault instance profile must be allowed to assume the target role:

```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::<account>:role/<target_iam_role_name>"
}
```

This is handled automatically by the trust policy set on `aws_iam_role.vault_target` — the module grants `vault_iam_user_arn` assume rights.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `vault_addr` | Address of the Vault server. | `string` | — | ✅ |
| `vault_token` | Vault token used by the `vault` provider during bootstrap. Should be a root or admin token; rotate after first apply. | `string` (sensitive) | — | ✅ |
| `tfe_hostname` | Hostname of the TFE instance (e.g. `tfe.example.com`). Works with any TFE — self-hosted or bring-your-own. | `string` | — | ✅ |
| `tfe_organization` | TFE organization name. | `string` | — | ✅ |
| `aws_secrets_backend_region` | AWS region the secrets engine uses for STS API calls. | `string` | — | ✅ |
| `vault_iam_user_arn` | ARN of the Vault EC2 IAM role (or IAM user) permitted to assume the target role. Pass `module.vault.iam_role_arn`. | `string` | — | ✅ |
| `vault_namespace` | Vault namespace. Leave empty for root. | `string` | `""` | |
| `vault_ca_cert_file` | Path to a PEM file for Vault's self-signed CA certificate. Required when Vault uses self-signed TLS. Alternatively set `VAULT_CACERT` in the environment. | `string` | `""` | |
| `tfe_project` | TFE project name. Use `"*"` to match all. | `string` | `"*"` | |
| `tfe_workspace` | TFE workspace name. Use `"*"` to match all. | `string` | `"*"` | |
| `jwt_backend_path` | Mount path for the JWT auth backend. | `string` | `"jwt-aws-provider"` | |
| `vault_role_name` | Name of the Vault JWT auth role. | `string` | `"tfe-vault-backed-aws"` | |
| `vault_policy_name` | Name of the Vault policy. | `string` | `"tfe-vault-backed-aws-policy"` | |
| `workload_identity_audience` | Expected `aud` claim in TFE JWT tokens. | `string` | `"vault.workload.identity"` | |
| `token_ttl_seconds` | Vault token TTL in seconds. | `number` | `1200` | |
| `aws_secrets_backend_path` | Mount path for the Vault AWS secrets engine. | `string` | `"aws"` | |
| `vault_aws_access_key_id` | Static AWS access key for Vault (leave empty to use EC2 instance profile). | `string` (sensitive) | `""` | |
| `vault_aws_secret_access_key` | Static AWS secret key for Vault (leave empty to use EC2 instance profile). | `string` (sensitive) | `""` | |
| `aws_secrets_role_name` | Name of the Vault AWS secrets engine role. | `string` | `"tfe-dynamic-aws-role"` | |
| `default_sts_ttl_seconds` | Default TTL for generated STS credentials. | `number` | `3600` | |
| `max_sts_ttl_seconds` | Maximum TTL for generated STS credentials. | `number` | `43200` | |
| `target_iam_role_name` | Name of the AWS IAM role Vault assumes to generate credentials. | `string` | `"vault-dynamic-creds-target"` | |
| `target_iam_policy_json` | IAM policy JSON for the target role. Defaults to a read-only EC2/S3 demo policy. | `string` | `""` | |
| `configure_tfe_workspace` | Create `tfe_variable` resources injecting the workspace env vars for this flow. | `bool` | `false` | |
| `tfe_workspace_id` | TFE workspace ID. Required when `configure_tfe_workspace = true`. | `string` | `""` | |
| `tfe_token` | TFE API token with permission to manage workspace variables. Required when `configure_tfe_workspace = true`. | `string` (sensitive) | `""` | |
| `vault_ca_cert_b64` | Base64-encoded PEM CA cert for self-signed Vault TLS. | `string` (sensitive) | `""` | |
| `set_vault_auth_vars` | When `true`, also inject the generic Vault auth vars (`TFC_VAULT_PROVIDER_AUTH`, `TFC_VAULT_ADDR`, `TFC_VAULT_AUTH_PATH`, `TFC_VAULT_RUN_ROLE`). Set `false` only if another process writes those same values for this AWS flow. | `bool` | `true` | |
| `create_jwt_backend` | When `true`, create the JWT auth backend at `jwt_backend_path`. Set `false` only to reuse an existing backend at that exact path. | `bool` | `true` | |
| `tfe_ca_cert_pem` | PEM-encoded CA cert for TFE's self-signed TLS certificate. Needed so Vault can verify TFE's OIDC discovery endpoint when `create_jwt_backend = true`. | `string` | `""` | |

## Outputs

| Name | Description |
|------|-------------|
| `aws_secrets_backend_path` | Mount path of the Vault AWS secrets engine. |
| `aws_secrets_role_name` | Name of the Vault AWS secrets engine role. |
| `jwt_backend_path` | Mount path of the JWT auth backend. |
| `vault_role_name` | Name of the JWT auth role. |
| `vault_policy_name` | Name of the Vault policy. |
| `target_iam_role_arn` | ARN of the AWS IAM role Vault assumes to generate credentials. |
| `tfe_workspace_env_vars` | Map of the non-sensitive workspace env vars for this flow. Add `TFC_VAULT_ENCODED_CACERT` and `TFC_VAULT_NAMESPACE` separately when needed. |

## TFE workspace environment variables

When `configure_tfe_workspace = false` (the default), set these in the TFE workspace manually:

| Variable | Value | Notes |
|----------|-------|-------|
| `TFC_VAULT_PROVIDER_AUTH` | `true` | Enables Vault-backed authentication |
| `TFC_VAULT_ADDR` | `https://vault.example.com:8200` | Must be reachable from TFE agents |
| `TFC_VAULT_AUTH_PATH` | `jwt-aws-provider` | Must match `jwt_backend_path` |
| `TFC_VAULT_RUN_ROLE` | `tfe-vault-backed-aws` | Must match `vault_role_name` |
| `TFC_VAULT_NAMESPACE` | `""` | Omit for the root namespace |
| `TFC_VAULT_BACKED_AWS_AUTH` | `true` | Enables vault-backed AWS credential injection |
| `TFC_VAULT_BACKED_AWS_AUTH_TYPE` | `assumed_role` | Must match secrets engine `credential_type` |
| `TFC_VAULT_BACKED_AWS_MOUNT_PATH` | `aws` | Must match `aws_secrets_backend_path` |
| `TFC_VAULT_BACKED_AWS_RUN_VAULT_ROLE` | `tfe-dynamic-aws-role` | Must match `aws_secrets_role_name` |
| `TFC_VAULT_BACKED_AWS_RUN_ROLE_ARN` | `arn:aws:iam::123456789012:role/vault-dynamic-creds-target` | Must match the IAM role Vault assumes |
| `TFC_VAULT_ENCODED_CACERT` | `<base64 PEM>` | Required for self-signed TLS (**sensitive**) |

The non-sensitive subset is also available as the `tfe_workspace_env_vars` output. Add `TFC_VAULT_ENCODED_CACERT` and, if used, `TFC_VAULT_NAMESPACE` separately.

> **Important:** Each dynamic credential flow needs its own `TFC_VAULT_AUTH_PATH` and `TFC_VAULT_RUN_ROLE`. Do not point a vault-backed AWS workspace at the `dynamic_provider_cred` backend/role.

## What resources are created

| Resource | Type | Notes |
|----------|------|-------|
| `auth/<jwt_backend_path>` | Vault JWT auth backend | |
| JWT auth role | Vault JWT auth role | `bound_claims` scoped to org/project/workspace |
| `<vault_policy_name>` | Vault policy | Token lifecycle + STS path read/update |
| `<aws_secrets_backend_path>` | Vault AWS secrets engine | Uses EC2 instance profile by default |
| `<aws_secrets_role_name>` | Vault AWS secrets engine role | `assumed_role` type |
| `<target_iam_role_name>` | AWS IAM role | Assumed by Vault to generate STS credentials |
| Inline role policy | AWS IAM policy | Defaults to read-only EC2/S3 demo permissions |

## References

- [Terraform Vault-backed dynamic credentials for AWS (validated pattern)](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws)
- [TFE vault-backed dynamic credentials — AWS configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-backed/aws-configuration)
- [Vault AWS secrets engine](https://developer.hashicorp.com/vault/docs/secrets/aws)
- [Vault AWS secrets engine — assumed_role credential type](https://developer.hashicorp.com/vault/docs/secrets/aws#assumed_role)
- [Vault JWT/OIDC auth method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [TFE workload identity tokens](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials/workload-identity-tokens)
- [hashicorp/vault Terraform provider](https://registry.terraform.io/providers/hashicorp/vault/latest/docs)
- [hashicorp/aws Terraform provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
