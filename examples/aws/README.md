# AWS examples

This example is intentionally split into two Terraform configurations:

```
aws/
├── infra/     # Deploy Vault Enterprise on AWS
└── dynamic/   # Configure dynamic credential flows in a running TFE instance
```

---

## infra/ — Deploy Vault on AWS

Creates a self-contained Vault Enterprise cluster on EC2 with its own VPC, KMS auto-unseal, and SSM-backed secret storage.

**Outputs written to SSM:**

| SSM path | Contents |
|---|---|
| `/vault/<cluster_name>/root_token` | Vault root token (SecureString) |
| `/vault/<cluster_name>/tls_cert_b64` | Base64-encoded Vault TLS cert |

### Steps

```bash
cd examples/aws/infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set region and cluster_name
export TF_VAR_vault_license="<your Vault Enterprise license>"
terraform init && terraform apply
```

Wait ~2–3 minutes for cloud-init to complete, then retrieve the root token:

```bash
aws ssm get-parameter \
  --name "$(terraform output -raw vault_root_token_ssm_path)" \
  --with-decryption \
  --query Parameter.Value --output text
```

---

## dynamic/ — Configure TFE dynamic secrets

Configures both dynamic credential flows against a running TFE/HCP Terraform instance. Uses the Vault address and credentials from `infra/` outputs.

**Prerequisites:**
- `infra/` has been applied and Vault is healthy
- A running TFE or HCP Terraform instance with an organization and API token

### Steps

```bash
cd examples/aws/dynamic
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: fill in Vault and TFE connection details
terraform init && terraform apply
```

This creates two workspaces in TFE and uploads test configurations to each:

| Workspace | Tests |
|---|---|
| `vault-kv-test` | Use Case A — JWT → short-lived Vault token → Vault KV read |
| `aws-creds-test` | Use Case B — JWT → Vault token → AWS STS creds injected as env vars |

After apply, trigger runs manually from the TFE UI. The upload step creates configuration versions only — it does **not** auto-queue runs.

### Passing Vault credentials

The `dynamic/` configuration accepts Vault credentials two ways:

**Option A — direct values** (simpler for one-off use):
```hcl
vault_root_token  = "<token>"
vault_ca_cert_b64 = "<base64 cert>"
```

**Option B — SSM paths** (cleaner pipeline; values are fetched at plan/apply time):
```hcl
vault_root_token_ssm_path  = "/vault/jit-demo/root_token"
vault_ca_cert_b64_ssm_path = "/vault/jit-demo/tls_cert_b64"
```

Both options are in `terraform.tfvars.example`.
