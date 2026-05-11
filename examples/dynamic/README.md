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

- A running Vault instance (deploy one via [`vault_enterprise_dev`](https://github.com/lukeb0t/vault_enterprise_dev), or bring your own)
- A running TFE or HCP Terraform instance with an organization and API token
- The Vault root token and base64-encoded TLS certificate available

### Retrieve Vault credentials

**AWS-hosted Vault** (deployed via `vault_enterprise_dev/vault_deploy_aws`):
```bash
vault_root_token=$(aws ssm get-parameter \
  --name /vault/<cluster_name>/root_token \
  --with-decryption --query Parameter.Value --output text)
vault_ca_cert_b64=$(aws ssm get-parameter \
  --name /vault/<cluster_name>/tls_cert_b64 \
  --query Parameter.Value --output text)
vault_addr="https://<vault-public-ip>:8200"
```

**Azure-hosted Vault** (deployed via `vault_enterprise_dev/vault_deploy_azure`):
```bash
vault_root_token=$(az keyvault secret show \
  --vault-name <key-vault-name> \
  --name vault-root-token --query value -o tsv)
vault_ca_cert_b64=$(az keyvault secret show \
  --vault-name <key-vault-name> \
  --name vault-tls-cert-b64 --query value -o tsv)
vault_addr="https://<vault-public-ip>:8200"
```

---

See each sub-directory's `README.md` for full usage instructions and variable reference.

