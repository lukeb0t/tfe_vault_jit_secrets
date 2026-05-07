# tfe_vault_jit_secrets

Terraform modules for deploying **HashiCorp Vault Enterprise** on AWS and configuring **just-in-time (JIT) dynamic secrets** for Terraform Enterprise (TFE) workloads — no long-lived credentials required.

This repo implements two HashiCorp validated patterns:

| Pattern | Module | Reference |
|---------|--------|-----------|
| TFE workspaces authenticate to Vault via JWT workload identity and receive a short-lived Vault token for the Vault Terraform provider | [`dynamic_provider_cred`](./dynamic_provider_cred/) | [Vault-backed dynamic credentials — Vault configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration) |
| Vault injects short-lived AWS STS credentials directly into TFE workspaces — no static AWS keys anywhere | [`dynamic_vault_secrets`](./dynamic_vault_secrets/) | [Terraform Vault-backed dynamic credentials for AWS](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws) |

---

## Repository layout

```
tfe_vault_jit_secrets/
├── vault_deploy_aws/       # Deploy Vault Enterprise on AWS (EC2 + VPC + KMS)
├── vault_deploy_azure/     # Deploy Vault Enterprise on Azure (VM + VNet + Azure Key Vault)
├── dynamic_provider_cred/  # TFE → Vault JWT auth (Vault provider creds)
├── dynamic_vault_secrets/  # TFE → Vault → AWS STS (vault-backed AWS creds)
└── examples/
    ├── aws/                # Minimal caller: vault_deploy_aws with defaults
    └── azure/              # Minimal caller: vault_deploy_azure with defaults
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         AWS Account                                      │
│                                                                          │
│   ┌──────────────┐   KMS Auto-Unseal   ┌─────────────────────────────┐ │
│   │  AWS KMS Key │◄────────────────────│   Vault Enterprise (EC2)    │ │
│   └──────────────┘                     │   Docker · Raft storage      │ │
│                                        │   Self-signed TLS            │ │
│   ┌──────────────┐   Init secrets      │   api_addr = EIP             │ │
│   │  SSM Param   │◄────────────────────│                              │ │
│   │  Store       │   (root token +     └──────────────┬──────────────┘ │
│   │  /vault/...  │    recovery keys)                  │                 │
│   └──────────────┘                                    │                 │
│                                                        │ JWT Auth        │
│                                        ┌───────────────▼──────────────┐ │
│                                        │   Terraform Enterprise (TFE) │ │
│                                        │                              │ │
│                                        │  Use Case A (dynamic_        │ │
│                                        │  provider_cred):             │ │
│                                        │  JWT → Vault token           │ │
│                                        │  → Vault Terraform provider  │ │
│                                        │                              │ │
│                                        │  Use Case B (dynamic_        │ │
│                                        │  vault_secrets):             │ │
│                                        │  JWT → Vault token           │ │
│                                        │  → Vault AWS secrets engine  │ │
│                                        │  → STS credentials injected  │ │
│                                        │    as env vars               │ │
│                                        └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Modules

### 1. [`vault_deploy_aws`](./vault_deploy_aws/)

Deploys a single-node Vault Enterprise server on AWS — fully self-contained. Creates its own VPC and networking by default (BYOVPC supported via `vpc_id`/`subnet_id` variables).

**Key features:**
- Vault Enterprise runs as a Docker container (image: `hashicorp/vault-enterprise`)
- AWS KMS auto-unseal — Vault unseals itself on (re)start without human intervention
- Self-signed TLS certificate with the EIP embedded as a SAN
- Raft integrated storage
- `vault operator init` runs automatically; root token + recovery keys stored in SSM Parameter Store as `SecureString`
- IMDSv2 enforced; hop limit 2 to allow the container to reach instance metadata

### 2. [`vault_deploy_azure`](./vault_deploy_azure/)

Deploys the same single-node Vault Enterprise cluster on **Azure** — a drop-in alternative to `vault_deploy_aws`. Creates its own VNet and networking by default (BYOVNET supported).

**Key features:**
- Vault Enterprise runs as a Docker container on Ubuntu 22.04 LTS
- **Azure Key Vault** auto-unseal — replaces both AWS KMS (unseal key) and SSM Parameter Store (secret storage)
- **User-Assigned Managed Identity** — replaces AWS IAM instance profile; identity lifecycle is independent of the VM
- Self-signed TLS certificate; static Standard-SKU public IP embedded as SAN
- `vault operator init` runs via cloud-init; root token + recovery keys stored as Azure Key Vault secrets

### 4. [`dynamic_provider_cred`](./dynamic_provider_cred/)

Configures Vault as an OIDC identity provider trusted by TFE. TFE workspaces exchange a workload-identity JWT for a short-lived Vault token scoped to a Vault policy — no Vault token management required.

**Key features:**
- JWT auth backend pointed at TFE's OIDC discovery URL
- `bound_claims` scoped to TFE org / project / workspace (supports glob matching)
- Vault policy granting token self-management + configurable secret paths
- Optional: automatically injects `TFC_VAULT_PROVIDER_AUTH`, `TFC_VAULT_ADDR`, `TFC_VAULT_RUN_ROLE` into the TFE workspace via `tfe_variable` resources

### 5. [`dynamic_vault_secrets`](./dynamic_vault_secrets/)

Extends the JWT auth pattern to deliver short-lived AWS STS credentials directly into TFE workspace environments via the Vault AWS secrets engine. Eliminates all static AWS credentials from TFE.

**Key features:**
- Vault AWS secrets engine using `assumed_role` credential type
- Target IAM role created in the same account; trust policy allows the Vault EC2 role to assume it
- Vault inherits AWS permissions from the EC2 instance profile — no static Vault IAM user keys required
- Optional: automatically injects all 7 `TFC_VAULT_BACKED_AWS_*` environment variables into the TFE workspace

---

## Quick start

### Prerequisites

- Terraform >= 1.5.0
- AWS credentials with sufficient permissions (EC2, IAM, KMS, SSM)
- A Vault Enterprise license string
- An existing AWS VPC with a public subnet — **or let the module create one automatically** (default behaviour)

### Step 1 — Deploy Vault

```hcl
module "vault" {
  source = "./vault_deploy_aws"

  cluster_name  = "my-vault"
  vault_version = "2.0.0-ent"
  vault_license = var.vault_license   # mark sensitive

  # VPC and subnet are created automatically.
  # To use an existing VPC: vpc_id = "vpc-xxx" and subnet_id = "subnet-xxx"
}
```

```bash
cd vault_deploy_aws
terraform init && terraform apply
```

Vault initialises automatically. Retrieve the root token once apply completes:

```bash
aws ssm get-parameter \
  --name "$(terraform output -raw ssm_root_token_path)" \
  --with-decryption \
  --query Parameter.Value --output text
```

### Step 2 — Configure TFE dynamic provider credentials (Use Case A)

```hcl
provider "vault" {
  address = module.vault.vault_addr
  token   = var.vault_root_token
}

module "dyn_provider" {
  source = "./dynamic_provider_cred"

  vault_addr       = module.vault.vault_addr
  tfe_hostname     = "tfe.example.com"
  tfe_organization = "my-org"
  tfe_workspace    = "my-workspace"
}
```

### Step 3 — Configure Vault-backed AWS credentials (Use Case B)

```hcl
provider "vault" {
  address = module.vault.vault_addr
  token   = var.vault_root_token
}

provider "aws" {
  region = "us-east-1"
}

module "dyn_aws" {
  source = "./dynamic_vault_secrets"

  vault_addr                 = module.vault.vault_addr
  tfe_hostname               = "tfe.example.com"
  tfe_organization           = "my-org"
  tfe_workspace              = "my-workspace"
  aws_secrets_backend_region = "us-east-1"

  # Pass the Vault EC2 role ARN so Vault can assume the target role
  vault_iam_user_arn = module.vault.iam_role_arn
}
```

---

## Examples

The `examples/aws/` directory is a minimal root module that calls `vault_deploy_aws` with defaults — useful for a quick smoke-test deployment.

```bash
cd examples/aws
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set vault_license
terraform init && terraform apply
```

---

## References

- [Vault Auto-unseal with AWS KMS](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms)
- [Vault operator init](https://developer.hashicorp.com/vault/docs/commands/operator/init)
- [TFE Dynamic Provider Credentials — overview](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials)
- [TFE Dynamic Provider Credentials — Vault configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-configuration)
- [Vault-backed dynamic credentials for AWS](https://developer.hashicorp.com/validated-patterns/terraform/terraform-vault-backed-dynamic-credentials-aws)
- [Vault-backed AWS credentials — TFE configuration](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/vault-backed/aws-configuration)
- [Vault JWT/OIDC auth method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Vault AWS secrets engine](https://developer.hashicorp.com/vault/docs/secrets/aws)
- [Vault Terraform provider](https://registry.terraform.io/providers/hashicorp/vault/latest/docs)
