# dynamic — Configure TFE dynamic secrets

Cloud-agnostic configurations that set up dynamic credential flows against a
running TFE or HCP Terraform instance. Works with Vault deployed on **AWS or Azure** (or anywhere).

Each sub-directory is a self-contained Terraform configuration for one use case:

| Directory | Use Case |
|-----------|----------|
| [`vault-provider/`](vault-provider/) | **JWT → Vault token** — TFE workspaces get a short-lived Vault token to use the Vault Terraform provider |
| [`aws-creds/`](aws-creds/) | **JWT → AWS STS credentials** — TFE workspaces get temporary AWS keys via the Vault AWS secrets engine |

---

## Prerequisites

- A running Vault instance (see [`examples/aws/infra/`](../aws/infra/) or [`examples/azure/infra/`](../azure/infra/))
- A running TFE or HCP Terraform instance with an organization and API token
- The Vault root token and base64-encoded TLS certificate available

### Retrieve Vault credentials

**AWS-hosted Vault:**
```bash
cd examples/aws/infra
vault_root_token=$(aws ssm get-parameter \
  --name "$(terraform output -raw vault_root_token_ssm_path)" \
  --with-decryption --query Parameter.Value --output text)
vault_ca_cert_b64=$(aws ssm get-parameter \
  --name "$(terraform output -raw vault_tls_cert_b64_ssm_path)" \
  --query Parameter.Value --output text)
vault_addr=$(terraform output -raw vault_addr)
```

**Azure-hosted Vault:**
```bash
cd examples/azure/infra
vault_root_token=$(az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name vault-root-token --query value -o tsv)
vault_ca_cert_b64=$(az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name vault-tls-cert-b64 --query value -o tsv)
vault_addr=$(terraform output -raw vault_addr)
```

---

See each sub-directory's `README.md` for full usage instructions and variable reference.

