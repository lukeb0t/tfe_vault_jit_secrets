# tfe_vault_jit_secrets

Terraform modules for deploying **HashiCorp Vault Enterprise** — on **AWS or Azure** — and configuring **just-in-time (JIT) dynamic secrets** for Terraform Enterprise (TFE) workloads. No long-lived credentials required.

This repo implements two HashiCorp validated patterns:

| Pattern | Module | Reference |
|---------|--------|-----------|
| TFE workspaces exchange a workload-identity JWT for a short-lived Vault token scoped to a Vault policy | [`dynamic_vault_secrets`](./dynamic_vault_secrets/) | [Vault-backed dynamic credentials — Vault configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration) |
| Vault injects short-lived AWS STS credentials directly into TFE workspace environments | [`dynamic_aws_provider_secrets`](./dynamic_aws_provider_secrets/) | [Terraform Vault-backed dynamic credentials for AWS](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws) |

---

## Repository layout

```
tfe_vault_jit_secrets/
│
│  ── Deploy infrastructure ──
├── vault_deploy_aws/       # Vault Enterprise on AWS   (EC2 + VPC + KMS + SSM)
├── vault_deploy_azure/     # Vault Enterprise on Azure (VM + VNet + Azure Key Vault)
│
│  ── Configure dynamic credential flows ──
├── dynamic_vault_secrets/         # TFE → jwt-vault-provider → Vault token → Vault provider
├── dynamic_aws_provider_secrets/  # TFE → jwt-aws-provider   → Vault token → AWS STS creds
│
└── examples/
    ├── aws/
    │   └── infra/     # Deploy vault_deploy_aws
    ├── azure/
    │   └── infra/     # Deploy vault_deploy_azure
    └── dynamic/
        ├── vault-provider/  # Use Case A: JWT → Vault token → Vault Terraform provider
        └── aws-creds/       # Use Case B: JWT → Vault → AWS STS credentials
```

---

## How it works

### Step 1 — Deploy Vault (choose AWS or Azure)

`vault_deploy_aws` and `vault_deploy_azure` are **equivalent, interchangeable modules**. Both deploy an identical single-node Vault Enterprise cluster; only the underlying cloud primitives differ. Pick the one that matches your environment.

| | `vault_deploy_aws` | `vault_deploy_azure` |
|---|---|---|
| **Compute** | EC2 (Amazon Linux 2023) | Linux VM (Ubuntu 22.04 LTS) |
| **Auto-unseal** | AWS KMS Customer Managed Key | Azure Key Vault RSA key |
| **Secret storage** | SSM Parameter Store (SecureString) | Azure Key Vault Secret |
| **Identity** | IAM Instance Profile | User-Assigned Managed Identity |
| **Networking** | VPC + subnet (auto or BYOVPC) | VNet + subnet (auto or BYOVNET) |
| **Public IP** | Elastic IP (pre-allocated) | Static Standard-SKU Public IP (pre-allocated) |
| **Bootstrap** | cloud-init via `user_data` | cloud-init via `custom_data` |
| **Vault config** | `seal "awskms"` | `seal "azurekeyvault"` |
| **Root token retrieval** | `aws ssm get-parameter ...` | `az keyvault secret show ...` |

Both modules:
- Run Vault Enterprise as a Docker container (`hashicorp/vault-enterprise`)
- Use Raft integrated storage
- TLS is enabled by default through an auto-generated, self-signed certificate. Both Vault modules also support BYO Cert/Key. See docs.
- Barebones dev mode is available in `vault_deploy_aws` for SSH-based bootstrap retrieval without KMS, IAM, or SSM bootstrap storage.
- Barebones dev mode is available in `vault_deploy_azure` for SSH-based bootstrap retrieval without Key Vault auto-unseal or Key Vault bootstrap secret storage.
- Run `vault operator init` automatically via cloud-init and, in default mode, store bootstrap secrets in cloud-native secret storage
- Support BYOVPC / BYOVNET via optional `vpc_id`/`subnet_id` (AWS) or `vnet_id`/`subnet_id` (Azure) inputs

### Step 2 — Configure TFE dynamic secrets (cloud-agnostic)

> **📋 Prerequisite:** The `dynamic_vault_secrets` and `dynamic_aws_provider_secrets` modules require a running **Terraform Enterprise (or HCP Terraform)** instance. You will need a TFE hostname, an organization, and an API token before applying either module.

Once Vault is running, the two dynamic-secrets modules work identically regardless of which cloud Vault is deployed on. They require:
- Vault server address and token (bootstrap credentials)
- TFE hostname and organization/workspace information
- TFE API token for workspace variable injection
- Vault's TLS certificate
- AWS-specific config (region, IAM role ARN for AWS module)

> **⚠️ Security Note — Bootstrap Tokens:** These examples use Vault root or admin tokens for bootstrapping only. **Do not use root tokens in production.** Instead, create a restricted policy scoped to JWT auth backend and secrets engine setup, authenticate with that token, rotate/revoke the bootstrap token after initial setup, and use TFE's workload identity (JWT) for ongoing operations.

See [`dynamic_vault_secrets`](./dynamic_vault_secrets/README.md) and [`dynamic_aws_provider_secrets`](./dynamic_aws_provider_secrets/README.md) for complete prerequisites and configuration details.

---

## Architecture

### AWS deployment

```
┌──────────────────────────────────────────────────────────────────────────┐
│  AWS Account                                                             │
│                                                                          │
│  ┌──────────────┐  KMS Auto-Unseal   ┌──────────────────────────────┐    │
│  │  KMS CMK     │◄───────────────────│  Vault Enterprise (EC2)      │    │
│  └──────────────┘                    │  Docker · Raft · self-signed │    │ 
│  ┌──────────────┐  Init secrets      │  TLS · api_addr = EIP        │    │
│  │  SSM Param   │◄───────────────────│                              │    │
│  │  Store       │  root token +      └──────────────┬───────────────┘    │
│  └──────────────┘  recovery keys                    │                    │
│                                                      │ JWT auth          │
│                                      ┌───────────────▼──────────────┐    │
│                                      │  Terraform Enterprise (TFE)  │    │
│                                      │                              │    │
│                                      │  Use Case A                  │    │
│                                      │  JWT → Vault token           │    │
│                                      │  → Vault Terraform provider  │    │
│                                      │                              │    │
│                                      │  Use Case B                  │    │
│                                      │  JWT → Vault token           │    │
│                                      │  → Vault AWS secrets engine  │    │
│                                      │  → STS creds injected as     │    │
│                                      │    env vars                  │    │
│                                      └──────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

### Azure deployment

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Azure Subscription                                                      │
│                                                                          │
│  ┌──────────────────┐  Key Vault Auto-Unseal                             │
│  │  Azure Key Vault │◄──────────────────────┐                            │
│  │  ├─ RSA key      │  (wrapKey/unwrapKey)  │                            │
│  │  └─ Secrets      │◄──────────────────┐   │                            │
│  └──────────────────┘  root token +     │   │                            │
│                         recovery keys   │   │                            │
│                                         │   │                            │
│  ┌──────────────────────────────────────┴───┴──────────────────────┐     │
│  │  Vault Enterprise (Linux VM)                                    │     │
│  │  Docker · Raft · self-signed TLS · api_addr = static public IP  │     │
│  │  User-Assigned Managed Identity → Key Vault RBAC                │     │
│  └─────────────────────────────────┬────────────────────────────── ┘     │
│                                    │ JWT auth                            │
│                    ┌───────────────▼──────────────┐                      │
│                    │  Terraform Enterprise (TFE)  │                      │
│                    │                              │                      │
│                    │  Use Case A                  │                      │
│                    │  JWT → Vault token           │                      │
│                    │  → Vault Terraform provider  │                      │
│                    │                              │                      │
│                    │  Use Case B                  │                      │
│                    │  JWT → Vault token           │                      │
│                    │  → Vault AWS secrets engine  │                      │
│                    │  → STS creds injected as     │                      │
│                    │    env vars                  │                      │
│                    └──────────────────────────────┘                      │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Modules

### [`vault_deploy_aws`](./vault_deploy_aws/) — Deploy Vault on AWS

Self-contained AWS deployment. Creates its own VPC and networking by default.

| Input | Description | Default |
|---|---|---|
| `cluster_name` | Name prefix for all resources | required |
| `vault_version` | Docker image tag | `"2.0.0-ent"` |
| `vault_license` | Enterprise license (sensitive) | required |
| `vpc_id` | Existing VPC (`null` = module creates one) | `null` |
| `subnet_id` | Existing subnet (required when `vpc_id` set) | `null` |
| `key_pair_name` | EC2 key pair for SSH access | `null` |

Key outputs: `vault_addr`, `vault_public_ip`, `ssm_root_token_path`, `ssm_tls_cert_b64_path`, `iam_role_arn`

→ See [`vault_deploy_aws/README.md`](./vault_deploy_aws/README.md) for full input/output reference.

---

### [`vault_deploy_azure`](./vault_deploy_azure/) — Deploy Vault on Azure

Self-contained Azure deployment. Creates its own VNet and networking by default.

| Input | Description | Default |
|---|---|---|
| `cluster_name` | Name prefix for all resources | required |
| `vault_version` | Docker image tag | `"2.0.0-ent"` |
| `vault_license` | Enterprise license (sensitive) | required |
| `location` | Azure region | required |
| `resource_group_name` | Existing Resource Group | required |
| `admin_ssh_public_key` | SSH public key for `azureuser` | required |
| `vnet_id` | Existing VNet (`null` = module creates one) | `null` |
| `subnet_id` | Existing subnet (required when `vnet_id` set) | `null` |

Key outputs: `vault_addr`, `vault_public_ip`, `key_vault_name`, `key_vault_uri`

→ See [`vault_deploy_azure/README.md`](./vault_deploy_azure/README.md) for full input/output reference.

---

### [`dynamic_vault_secrets`](./dynamic_vault_secrets/) — Use Case A: TFE Vault Provider Credentials

Configures Vault JWT auth to trust TFE workload identity tokens. Workspaces receive a short-lived Vault token without managing any static credential.

**Works with Vault deployed on either AWS or Azure.**

→ Reference: [Vault-backed dynamic credentials — Vault configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration)

---

### [`dynamic_aws_provider_secrets`](./dynamic_aws_provider_secrets/) — Use Case B: TFE Vault-Backed AWS Credentials

Extends Use Case A: Vault exchanges the TFE JWT for short-lived AWS STS credentials via the Vault AWS secrets engine. Eliminates all static AWS credentials from TFE.

**Works with Vault deployed on either AWS or Azure.**

→ Reference: [Terraform Vault-backed dynamic credentials for AWS](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws)

---

## Quick Start

### Option A — Vault on AWS

```bash
cd examples/aws/infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set region, cluster_name, and vault_license
export TF_VAR_vault_license="<your Vault license>"
terraform init && terraform apply
```

Retrieve the root token after cloud-init completes (~2–3 min):

```bash
aws ssm get-parameter \
  --name "$(terraform output -raw vault_root_token_ssm_path)" \
  --with-decryption \
  --query Parameter.Value --output text
```

### Option B — Vault on Azure

```bash
cd examples/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set vault_license, location, resource_group_name, admin_ssh_public_key
export TF_VAR_vault_license="<your license>"
terraform init && terraform apply
```

Retrieve the root token after cloud-init completes (~3–5 min):

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name vault-root-token \
  --query value -o tsv
```

### Step 2 — Configure TFE dynamic secrets

**Bring your own TFE server.** You need a running Terraform Enterprise or HCP Terraform instance before applying the dynamic modules. Have the following ready:

| Value | Where to find it |
|---|---|
| `tfe_hostname` | Your TFE FQDN, e.g. `tfe.example.com` or `app.terraform.io` |
| `tfe_org_name` | Organization name in TFE/HCP Terraform |
| `tfe_org_token` | TFE org-level API token (Settings → API Tokens) |

`examples/dynamic/` is **cloud-agnostic** — it works with Vault deployed on AWS or Azure. Each sub-directory targets a single use case:

| Use Case | Directory |
|----------|-----------|
| JWT → Vault token (Vault Terraform provider) | [`examples/dynamic/vault-provider/`](./examples/dynamic/vault-provider/) |
| JWT → AWS STS credentials (via Vault AWS secrets engine) | [`examples/dynamic/aws-creds/`](./examples/dynamic/aws-creds/) |

```bash
# Use Case A — Vault provider credentials
cd examples/dynamic/vault-provider
cp terraform.tfvars.example terraform.tfvars
# Set vault_addr, vault_root_token, vault_ca_cert_b64, tfe_hostname, tfe_org_token, tfe_org_name
terraform init && terraform apply

# Use Case B — Vault-backed AWS dynamic credentials
cd examples/dynamic/aws-creds
cp terraform.tfvars.example terraform.tfvars
# Set vault_addr, vault_root_token, vault_ca_cert_b64, vault_iam_principal_arn, tfe_hostname, tfe_org_token, tfe_org_name
terraform init && terraform apply
```

Each apply creates a dedicated test workspace and uploads its test config. Trigger runs manually from the TFE UI.

---

## Prerequisites

| Requirement | AWS | Azure |
|---|---|---|
| Terraform | ≥ 1.5.0 | ≥ 1.5.0 |
| CLI auth | `aws configure` or env vars | `az login` or `ARM_*` env vars |
| IAM/RBAC permissions | EC2, VPC, IAM, KMS, SSM | Contributor + Key Vault Administrator |
| Vault Enterprise license | required | required |
| Pre-existing network | optional (module creates VPC) | optional (module creates VNet) |
| SSH key pair | optional (`key_pair_name`) | required (`admin_ssh_public_key`) |
| TFE / HCP Terraform instance | required for dynamic modules | required for dynamic modules |

---

## References

**Vault**
- [Vault Auto-Unseal with AWS KMS](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms)
- [Vault Auto-Unseal with Azure Key Vault](https://developer.hashicorp.com/vault/docs/configuration/seal/azurekeyvault)
- [Vault `operator init`](https://developer.hashicorp.com/vault/docs/commands/operator/init)
- [Vault Enterprise Licensing](https://developer.hashicorp.com/vault/docs/enterprise/license)
- [Vault Docker image (`hashicorp/vault-enterprise`)](https://hub.docker.com/r/hashicorp/vault-enterprise)

**TFE Dynamic Credentials**
- [TFE Dynamic Provider Credentials — overview](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials)
- [TFE Dynamic Provider Credentials — Vault configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration)
- [Vault-backed dynamic credentials for AWS](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws)
- [Vault-backed AWS credentials — TFE configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-backed/aws-configuration)
- [Vault JWT/OIDC auth method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Vault AWS secrets engine](https://developer.hashicorp.com/vault/docs/secrets/aws)
- [Vault Terraform provider](https://registry.terraform.io/providers/hashicorp/vault/latest/docs)

**Azure**
- [Azure User-Assigned Managed Identity](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/how-manage-user-assigned-managed-identities)
- [Azure Key Vault RBAC guide](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
