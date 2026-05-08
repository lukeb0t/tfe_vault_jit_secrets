# dynamic_vault_secrets

Terraform module that configures **Vault-backed dynamic AWS credentials for Terraform Enterprise**. TFE workspaces authenticate to Vault via JWT workload identity; Vault then generates short-lived AWS STS credentials via the AWS secrets engine and injects them directly into the workspace environment. No static AWS access keys are stored anywhere.

**Reference:** [Terraform Vault-backed dynamic credentials for AWS](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws)

## How it works

```
TFE workspace run
      │
      │  1. TFE mints a workload-identity JWT
      ▼
Vault JWT auth backend
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

### Minimal

```hcl
provider "vault" {
  address = "https://vault.example.com:8200"
  token   = var.vault_root_token   # bootstrap only
}

provider "aws" {
  region = "us-east-1"   # credentials for creating the target IAM role
}

module "dyn_aws" {
  source = "./dynamic_vault_secrets"

  vault_addr                 = "https://vault.example.com:8200"
  tfe_hostname               = "tfe.example.com"
  tfe_organization           = "my-org"
  aws_secrets_backend_region = "us-east-1"

  # ARN of the Vault EC2 instance role — allows Vault to call sts:AssumeRole
  vault_iam_user_arn = "arn:aws:iam::123456789012:role/my-vault-server"
}
```

When using alongside `vault_deploy_aws`, pass the IAM role ARN directly from that module's output:

```hcl
module "dyn_aws" {
  source = "./dynamic_vault_secrets"

  vault_iam_user_arn = module.vault.iam_role_arn
  # ...
}
```

### With custom IAM permissions for the target role

```hcl
module "dyn_aws" {
  source = "./dynamic_vault_secrets"

  vault_addr                 = "https://vault.example.com:8200"
  tfe_hostname               = "tfe.example.com"
  tfe_organization           = "my-org"
  tfe_workspace              = "infra-prod"
  aws_secrets_backend_region = "us-east-1"
  vault_iam_user_arn         = module.vault.iam_role_arn

  target_iam_role_name = "tfe-infra-prod-role"

  target_iam_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:*", "s3:*", "iam:PassRole"]
      Resource = "*"
    }]
  })
}
```

### With automatic TFE workspace variable injection

```hcl
module "dyn_aws" {
  source = "./dynamic_vault_secrets"

  # ... required inputs ...

  configure_tfe_workspace = true
  tfe_workspace_id        = "ws-XXXXXXXXXXXXXXXX"
  vault_ca_cert_b64       = base64encode(file("vault-ca.pem"))
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| hashicorp/aws | ~> 5.0 |
| hashicorp/vault | ~> 4.0 |
| hashicorp/tfe | ~> 0.57 (optional — only when `configure_tfe_workspace = true`) |

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
| `tfe_hostname` | Hostname of the self-hosted TFE instance. | `string` | — | ✅ |
| `tfe_organization` | TFE organization name. | `string` | — | ✅ |
| `aws_secrets_backend_region` | AWS region the secrets engine uses for STS API calls. | `string` | — | ✅ |
| `vault_iam_user_arn` | ARN of the Vault EC2 IAM role (or IAM user) permitted to assume the target role. Pass `module.vault.iam_role_arn`. | `string` | — | ✅ |
| `vault_namespace` | Vault namespace. Leave empty for root. | `string` | `""` | |
| `tfe_project` | TFE project name. Use `"*"` to match all. | `string` | `"*"` | |
| `tfe_workspace` | TFE workspace name. Use `"*"` to match all. | `string` | `"*"` | |
| `jwt_backend_path` | Mount path for the JWT auth backend. | `string` | `"jwt"` | |
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
| `configure_tfe_workspace` | Create `tfe_variable` resources injecting all required env vars. Requires `tfe` provider. | `bool` | `false` | |
| `tfe_workspace_id` | TFE workspace ID. Required when `configure_tfe_workspace = true`. | `string` | `""` | |
| `vault_ca_cert_b64` | Base64-encoded PEM CA cert for self-signed Vault TLS. | `string` (sensitive) | `""` | |

## Outputs

| Name | Description |
|------|-------------|
| `aws_secrets_backend_path` | Mount path of the Vault AWS secrets engine. |
| `aws_secrets_role_name` | Name of the Vault AWS secrets engine role. |
| `jwt_backend_path` | Mount path of the JWT auth backend. |
| `vault_role_name` | Name of the JWT auth role. |
| `vault_policy_name` | Name of the Vault policy. |
| `target_iam_role_arn` | ARN of the AWS IAM role Vault assumes to generate credentials. |
| `tfe_workspace_env_vars` | Map of all environment variables required in the TFE workspace. |

## TFE workspace environment variables

When `configure_tfe_workspace = false` (the default), set these in the TFE workspace manually:

| Variable | Value | Notes |
|----------|-------|-------|
| `TFC_VAULT_PROVIDER_AUTH` | `true` | Enables Vault dynamic credentials |
| `TFC_VAULT_ADDR` | `https://vault.example.com:8200` | Must be reachable from TFE agents |
| `TFC_VAULT_RUN_ROLE` | `tfe-vault-backed-aws` | Must match `vault_role_name` |
| `TFC_VAULT_BACKED_AWS_AUTH` | `true` | Enables vault-backed AWS credential injection |
| `TFC_VAULT_BACKED_AWS_AUTH_TYPE` | `assumed_role` | Must match secrets engine `credential_type` |
| `TFC_VAULT_BACKED_AWS_ROLE` | `tfe-dynamic-aws-role` | Must match `aws_secrets_role_name` |
| `TFC_VAULT_BACKED_AWS_MOUNT_PATH` | `aws` | Must match `aws_secrets_backend_path` |
| `TFC_VAULT_BACKED_AWS_RUN_ROLE` | `tfe-vault-backed-aws` | Must match `vault_role_name` |
| `TFC_VAULT_ENCODED_CACERT` | `<base64 PEM>` | Required for self-signed TLS (**sensitive**) |

These are also available as the `tfe_workspace_env_vars` output.

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
