# Use Case: Vault-backed AWS Dynamic Credentials

Demonstrates TFE workload identity JWT authentication to Vault, where Vault
exchanges the JWT for a short-lived AWS STS credential via the
[Vault AWS secrets engine](https://developer.hashicorp.com/vault/docs/secrets/aws).
TFE injects `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN`
into the target workspace automatically — no static IAM keys stored anywhere.

## What this configures

| Resource | Description |
|----------|-------------|
| JWT auth backend | Vault backend at `jwt-aws-provider/` that trusts TFE OIDC tokens |
| AWS secrets engine | Vault backend that generates STS `assumed_role` credentials |
| Vault role | Bound to any workspace in the configured TFE org/project |
| TFE workspace | `aws-creds-test` — receives injected AWS creds and lists EC2 AZs |
| TFE variables | `TFC_VAULT_*` and `TFC_VAULT_BACKED_AWS_*` env vars wired automatically |

## Prerequisites

- A running Vault instance deployed in AWS with an IAM role that can `sts:AssumeRole`
  (deploy one via [`vault_enterprise_dev/examples/aws/infra`](https://github.com/lukeb0t/vault_enterprise_dev/tree/main/examples/aws/infra), or bring your own)
- A running TFE instance with an organization and organization token
- An IAM role for Vault to assume-role into (the `dynamic_aws_provider_secrets` module creates this)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Vault addr, root token, IAM role ARN, TFE details

terraform init
terraform apply
```

### Retrieving Vault credentials

**AWS** (Vault deployed via `vault_enterprise_dev/examples/aws/infra`):
```bash
vault_root_token=$(aws ssm get-parameter \
  --name /vault/<cluster_name>/root_token --with-decryption \
  --query Parameter.Value --output text)

vault_ca_cert_b64=$(aws ssm get-parameter \
  --name /vault/<cluster_name>/tls_cert_b64 \
  --query Parameter.Value --output text)

# Vault IAM role ARN (from vault_enterprise_dev infra outputs):
vault_iam_principal_arn=$(terraform -chdir=<path-to-vault_enterprise_dev>/examples/aws/infra output -raw vault_iam_role_arn)
```

## Test workspace

After `apply`, open the `aws-creds-test` workspace in TFE and queue a plan.
The test config (`test/aws-creds-test/main.tf`) uses the injected STS
credentials to list EC2 availability zones, confirming successful auth.

## How it works

```
TFE workspace plan/apply
  → sends workload identity JWT to Vault at jwt-aws-provider/
  → Vault validates JWT, calls sts:AssumeRole
  → returns AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
  → TFE injects credentials as env vars into the workspace run
```

## Outputs

| Output | Description |
|--------|-------------|
| `tfe_workspace_url` | Direct link to the test workspace |
| `vault_jwt_backend_path` | JWT auth backend path in Vault |
| `aws_secrets_backend_path` | Vault AWS secrets engine mount |
| `aws_secrets_role_name` | Vault role used for STS generation |
| `target_iam_role_arn` | IAM role TFE workspaces assume via Vault |
