# Use Case: Vault Provider Dynamic Credentials

Demonstrates TFE workload identity JWT authentication to Vault, where TFE
exchanges a short-lived JWT for a Vault token scoped to a specific policy.
The Vault token is injected as `VAULT_TOKEN` into the target workspace so it
can use the [Vault Terraform provider](https://registry.terraform.io/providers/hashicorp/vault/latest)
without storing long-lived credentials.

## What this configures

| Resource | Description |
|----------|-------------|
| JWT auth backend | Vault backend at `jwt-vault-provider/` that trusts TFE OIDC tokens |
| Vault role | Bound to any workspace in the configured TFE org/project |
| KV secrets engine | Demo mount at `kv/` with a sample secret at `kv/data/demo/app` |
| TFE workspace | `vault-kv-test` — reads the KV secret via the Vault provider |
| TFE variables | `TFC_VAULT_*` env vars wired to the workspace automatically |

## Prerequisites

- A running Vault instance (see `examples/aws/infra/` or `examples/azure/infra/`)
- A running TFE instance with an organization and organization token
- The `dynamic_vault_secrets` module available in the parent repo

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Vault addr, root token, TFE hostname/org/token

terraform init
terraform apply
```

### Retrieving credentials

**AWS** (Vault deployed via `examples/aws/infra/`):
```bash
vault_root_token=$(aws ssm get-parameter \
  --name /vault/root_token --with-decryption \
  --query Parameter.Value --output text)

vault_ca_cert_b64=$(aws ssm get-parameter \
  --name /vault/ca_cert_b64 --with-decryption \
  --query Parameter.Value --output text)
```

**Azure** (Vault deployed via `examples/azure/infra/`):
```bash
vault_root_token=$(az keyvault secret show \
  --vault-name <kv-name> --name vault-root-token \
  --query value -o tsv)

vault_ca_cert_b64=$(az keyvault secret show \
  --vault-name <kv-name> --name vault-ca-cert-b64 \
  --query value -o tsv)
```

## Test workspace

After `apply`, open the `vault-kv-test` workspace in TFE and queue a plan.
The test config (`test/vault-kv-test/main.tf`) reads `kv/data/demo/app` and
outputs the secret keys (not values) to confirm successful auth.

## Outputs

| Output | Description |
|--------|-------------|
| `tfe_workspace_url` | Direct link to the test workspace |
| `vault_jwt_backend_path` | JWT auth backend path in Vault |
| `vault_role_name` | Vault role assigned to the workspace |
| `kv_mount_path` | KV mount where demo secrets are stored |
