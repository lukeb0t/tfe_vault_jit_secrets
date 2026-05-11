# dynamic_aws_provider_secrets

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

## Prerequisites

This module configures Vault to issue dynamic AWS credentials to TFE workspaces. Before applying:

1. **Create a TFE workspace** where you want to use dynamic AWS credentials. (The workspace must exist first; this module injects variables into it but does not create it.)

2. **Gather workspace information** for JWT claim scoping:
   - `tfe_organization` — Your TFE organization name (e.g., `my-org`)
   - `tfe_project` — Project containing the workspace (e.g., `my-project`), or `"*"` to match all
   - `tfe_workspace` — Workspace name (e.g., `prod`), or `"*"` to match all workspaces in the project

   > **Note:** These are used to scope Vault's JWT authentication. Only workspaces matching this pattern can authenticate to Vault and obtain AWS credentials. In production, use specific workspace names for security; use `"*"` wildcards only in development.

3. **Obtain the workspace ID**: In TFE, go to Settings → General for the workspace. The ID appears as `ws-XXXXXXXXXXXXXXXX`.

4. **Generate a TFE API token** with permission to manage workspace variables: Settings → Tokens → Create an API token. (Scoped to the organization is sufficient.)

5. **Vault must be accessible** from TFE agents (via `tfe_hostname` and `vault_addr`). If either uses self-signed TLS, provide the CA certificate (`tfe_ca_cert_pem` and/or `vault_ca_cert_b64`).

## Usage

Copy `terraform.tfvars.example` to `terraform.tfvars`, fill in your values, then:

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

tfe_hostname     = "tfe.example.com"   # any TFE instance — self-hosted or bring-your-own
tfe_organization = "my-org"
tfe_workspace_id = "ws-XXXXXXXXXXXXXXXX"
tfe_token        = "TOKEN"

aws_secrets_backend_region = "us-east-1"

# ARN of the Vault EC2 instance role — allows Vault to call sts:AssumeRole.
# When using alongside vault_deploy_aws: vault_iam_user_arn = module.vault.iam_role_arn
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


### AWS permissions required by the caller

To create the target IAM role, the Terraform principal needs:

- `iam:CreateRole`, `iam:PutRolePolicy`, `iam:DeleteRole`, `iam:DeleteRolePolicy`

### AWS permissions required by Vault

Vault needs an IAM principal (user or role) that can call `sts:AssumeRole` on the target role. Supply its credentials via `vault_aws_access_key_id` / `vault_aws_secret_access_key`, and set `vault_iam_user_arn` to that principal's ARN so the target role's trust policy allows it.

If Vault happens to run on EC2 in the same AWS account, you can omit the static credentials and set `vault_iam_user_arn` to the instance role ARN instead — Vault will use the instance profile automatically.

The trust policy on the target role is managed by this module; no manual IAM changes are required.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `vault_addr` | Address of the Vault server. | `string` | — | ✅ |
| `vault_token` | Vault token used by the `vault` provider during bootstrap. Should be a root or admin token; rotate after first apply. | `string` (sensitive) | — | ✅ |
| `tfe_hostname` | Hostname of the TFE instance (e.g. `tfe.example.com`). Works with any TFE — self-hosted or bring-your-own. | `string` | — | ✅ |
| `tfe_organization` | TFE organization name. Used to scope JWT `bound_claims` — only workspaces in this org can authenticate. | `string` | — | ✅ |
| `tfe_workspace_id` | TFE workspace ID (e.g., `ws-XXXXXXXXXXXXXXXX`). Found in workspace Settings → General. | `string` | — | ✅ |
| `tfe_token` | TFE API token with permission to manage workspace variables. | `string` (sensitive) | — | ✅ |
| `aws_secrets_backend_region` | AWS region the secrets engine uses for STS API calls. | `string` | — | ✅ |
| `vault_iam_user_arn` | ARN of the IAM principal Vault authenticates as (IAM user ARN for static credentials, or IAM role ARN if Vault runs on EC2). Granted `sts:AssumeRole` on the target role. | `string` | — | ✅ |
| `vault_aws_access_key_id` | AWS access key ID for the IAM user Vault authenticates as. Required when Vault is not on EC2 with a suitable instance profile. | `string` (sensitive) | `""` | |
| `vault_aws_secret_access_key` | AWS secret access key paired with `vault_aws_access_key_id`. | `string` (sensitive) | `""` | |
| `vault_namespace` | Vault namespace. Leave empty for root. | `string` | `""` | |
| `vault_ca_cert_file` | Path to a PEM file for Vault's self-signed CA certificate. Required when Vault uses self-signed TLS. Alternatively set `VAULT_CACERT` in the environment. | `string` | `""` | |
| `vault_ca_cert_b64` | Base64-encoded PEM CA cert for Vault. Injected as `TFC_VAULT_ENCODED_CACERT`. Required for self-signed TLS. | `string` (sensitive) | `""` | |
| `tfe_project` | TFE project name. Used to scope JWT `bound_claims`. Use `"*"` to match all projects in the organization. | `string` | `"*"` | |
| `tfe_workspace` | TFE workspace name. Used to scope JWT `bound_claims`. Use `"*"` to match all workspaces in the project. | `string` | `"*"` | |
| `tfe_ca_cert_pem` | PEM-encoded CA cert for TFE's self-signed TLS certificate. Needed so Vault can verify TFE's OIDC discovery endpoint when `create_jwt_backend = true`. | `string` | `""` | |
| `jwt_backend_path` | Mount path for the JWT auth backend. | `string` | `"jwt-aws-provider"` | |
| `vault_role_name` | Name of the Vault JWT auth role. | `string` | `"tfe-vault-backed-aws"` | |
| `vault_policy_name` | Name of the Vault policy. | `string` | `"tfe-vault-backed-aws-policy"` | |
| `workload_identity_audience` | Expected `aud` claim in TFE JWT tokens. | `string` | `"vault.workload.identity"` | |
| `token_ttl_seconds` | Vault token TTL in seconds. | `number` | `1200` | |
| `aws_secrets_backend_path` | Mount path for the Vault AWS secrets engine. | `string` | `"aws"` | |
| `aws_secrets_role_name` | Name of the Vault AWS secrets engine role. | `string` | `"tfe-dynamic-aws-role"` | |
| `default_sts_ttl_seconds` | Default TTL for generated STS credentials. | `number` | `3600` | |
| `max_sts_ttl_seconds` | Maximum TTL for generated STS credentials. | `number` | `43200` | |
| `target_iam_role_name` | Name of the AWS IAM role Vault assumes to generate credentials. | `string` | `"vault-dynamic-creds-target"` | |
| `target_iam_policy_json` | IAM policy JSON for the target role. Defaults to a read-only EC2/S3 demo policy. | `string` | `""` | |
| `set_vault_auth_vars` | When `true`, also inject the generic Vault auth vars (`TFC_VAULT_PROVIDER_AUTH`, `TFC_VAULT_ADDR`, `TFC_VAULT_AUTH_PATH`, `TFC_VAULT_RUN_ROLE`). Set `false` only if another process writes those same values for this AWS flow. | `bool` | `true` | |
| `create_jwt_backend` | When `true`, create the JWT auth backend at `jwt_backend_path`. Set `false` only to reuse an existing backend at that exact path. | `bool` | `true` | |

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

For manual setup, set these in the TFE workspace instead:

| Variable | Value | Notes |
|----------|-------|-------|
| `TFC_VAULT_PROVIDER_AUTH` | `true` | Enables Vault-backed authentication |
| `TFC_VAULT_ADDR` | `https://vault.example.com:8200` | Must be reachable from TFE agents |
| `TFC_VAULT_AUTH_PATH` | `jwt-aws-provider` | Must match `jwt_backend_path` |
| `TFC_VAULT_RUN_ROLE` | `tfe-vault-backed-aws` | Must match `vault_role_name` |
| `TFC_VAULT_NAMESPACE` | `""` | Omit for the root namespace |
| `TFC_VAULT_BACKED_AWS_AUTH` | `true` | Enables vault-backed AWS credential injection |
| `TFC_VAULT_BACKED_AWS_AUTH_PATH` | `jwt-aws-provider` | Must match the JWT backend used by this AWS flow |
| `TFC_VAULT_BACKED_AWS_AUTH_TYPE` | `assumed_role` | Must match secrets engine `credential_type` |
| `TFC_VAULT_BACKED_AWS_MOUNT_PATH` | `aws` | Must match `aws_secrets_backend_path` |
| `TFC_VAULT_BACKED_AWS_RUN_VAULT_ROLE` | `tfe-dynamic-aws-role` | Must match `aws_secrets_role_name` |
| `TFC_VAULT_BACKED_AWS_RUN_ROLE_ARN` | `arn:aws:iam::123456789012:role/vault-dynamic-creds-target` | Must match the IAM role Vault assumes |
| `TFC_VAULT_ENCODED_CACERT` | `<base64 PEM>` | Required for self-signed TLS (**sensitive**) |

The non-sensitive subset is also available as the `tfe_workspace_env_vars` output. Add `TFC_VAULT_ENCODED_CACERT` and, if used, `TFC_VAULT_NAMESPACE` separately.

> **Important:** Each dynamic credential flow needs its own `TFC_VAULT_AUTH_PATH` and `TFC_VAULT_RUN_ROLE`. Do not point a vault-backed AWS workspace at the `dynamic_vault_secrets` backend/role.
>
> **Multiple JWT backends:** If using both `dynamic_vault_secrets` and `dynamic_aws_provider_secrets`, ensure they have different `workload_identity_audience` values (e.g., `vault.workload.identity.kv` vs. `vault.workload.identity.aws`). This prevents a single TFE workspace from matching multiple Vault roles—a critical security boundary.

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
