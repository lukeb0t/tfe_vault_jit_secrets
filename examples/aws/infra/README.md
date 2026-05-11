# aws/infra — Deploy Vault on AWS

Creates a self-contained Vault Enterprise cluster on EC2 with its own VPC, KMS auto-unseal, and SSM-backed secret storage.

> **Module source:** [`vault_enterprise_dev//vault_deploy_aws`](https://github.com/lukeb0t/vault_enterprise_dev/tree/main/vault_deploy_aws) — sourced directly from GitHub.

---

## Modes

### Default mode (`barebones_dev_mode` not set)

Creates the full production-like stack:

| Resource | Purpose |
|---|---|
| AWS KMS CMK | Auto-unseal |
| SSM Parameter Store | Root token + TLS cert (SecureString) |
| EC2 Instance | Runs Vault Enterprise in Docker with Raft storage |
| VPC + subnet + SG | Isolated network (or bring your own) |
| Elastic IP | Stable `api_addr` for the Vault listener |

**Bootstrap secrets written to SSM:**

| SSM path | Contents |
|---|---|
| `/vault/<cluster_name>/root_token` | Vault root token (SecureString) |
| `/vault/<cluster_name>/tls_cert_b64` | Base64-encoded self-signed TLS certificate |

### Barebones dev mode (`barebones_dev_mode = true`)

Skips KMS, IAM, and SSM secret storage. Vault is initialized with a single Shamir unseal key and credentials are written to `/opt/vault/bootstrap/bootstrap.json` on the instance. Intended for short-lived dev/test environments only.

---

## Steps

```bash
cd examples/aws/infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set region and cluster_name
export TF_VAR_vault_license="<your Vault Enterprise license>"
terraform init && terraform apply
```

Wait ~2–3 minutes for cloud-init to complete.

### Retrieve the root token (default mode)

```bash
aws ssm get-parameter \
  --name "$(terraform output -raw vault_root_token_ssm_path)" \
  --with-decryption \
  --query Parameter.Value --output text
```

### Retrieve the TLS certificate (default mode)

```bash
aws ssm get-parameter \
  --name "$(terraform output -raw vault_tls_cert_b64_ssm_path)" \
  --query Parameter.Value --output text | base64 -d > vault.crt
export VAULT_CACERT=vault.crt
```

### Retrieve bootstrap credentials (barebones mode)

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)"
sudo cat /opt/vault/bootstrap/bootstrap.json
```

---

## Outputs

| Output | Description |
|---|---|
| `vault_addr` | Vault HTTPS address — set as `VAULT_ADDR` |
| `vault_public_ip` | Elastic IP of the EC2 instance |
| `vault_root_token_ssm_path` | SSM path for the root token |
| `vault_tls_cert_b64_ssm_path` | SSM path for the base64-encoded TLS cert |
| `vault_iam_role_arn` | IAM role ARN attached to the instance |

---

## Bring your own network

To deploy into an existing VPC, set `vpc_id` and `subnet_id` in your `terraform.tfvars`:

```hcl
vpc_id    = "vpc-0abc123"
subnet_id = "subnet-0abc123"
```

---

## Next step

Once Vault is healthy, configure TFE dynamic credential flows using [`examples/dynamic/`](../../dynamic/).
