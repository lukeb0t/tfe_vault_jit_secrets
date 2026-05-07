# vault_deploy_azure

Deploys a single-node **Vault Enterprise** cluster on an Azure Linux VM (Ubuntu 22.04 LTS) using Docker and Azure Key Vault for auto-unseal and secret storage. This module is the Azure equivalent of `vault_deploy_aws` — the two modules share the same interface and can be used interchangeably depending on the customer's target cloud.

## Architecture

```
Azure Resource Group
└── Virtual Network  ← module-managed (BYOVNET supported via vnet_id/subnet_id)
    └── Subnet
        ├── Network Security Group
        │   ├── Inbound TCP 8200  (Vault HTTPS API + UI)
        │   └── Inbound TCP 22    (SSH — conditional, empty list = disabled)
        ├── Public IP (Static, Standard SKU)  ← pre-allocated before VM boots
        └── Network Interface
            └── Linux VM (Ubuntu 22.04 LTS)
                ├── custom_data → cloud-init bootstrap script
                └── User-Assigned Managed Identity
Azure Key Vault (Premium SKU)
├── RSA 2048 key  → Vault auto-unseal (wrapKey / unwrapKey)
└── Secrets       → vault-root-token + vault-recovery-key-{1..5}
```

### AWS ↔ Azure component mapping

| AWS Component | Azure Equivalent |
|---|---|
| KMS Customer Managed Key | Azure Key Vault RSA key |
| SSM Parameter Store (SecureString) | Azure Key Vault Secret |
| IAM Instance Profile | User-Assigned Managed Identity |
| `seal "awskms"` in vault.hcl | `seal "azurekeyvault"` in vault.hcl |
| Elastic IP (pre-allocated) | Static Standard-SKU Public IP (pre-allocated) |
| AWS IMDSv2 | Azure IMDS (no token exchange required) |

The static public IP is allocated by Terraform before the VM is created and passed into `templatefile()` — the same pattern as the AWS EIP. This ensures the TLS certificate SAN and `api_addr` are correct from the first boot.

## Prerequisites

- Terraform ≥ 1.5.0
- `az login` (or service principal via `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID` environment variables)
- An existing **Azure Resource Group**
- An SSH public key string (required by Azure even when SSH port is not opened)
- A Vault Enterprise license string

## Quick Start

```bash
cd examples/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set resource_group_name, admin_ssh_public_key, etc.
export TF_VAR_vault_license="<your license>"
terraform init
terraform apply
```

After `terraform apply` completes, cloud-init bootstraps Vault on first boot (~3–5 minutes). Once complete:

```bash
# Retrieve the root token from Azure Key Vault
az keyvault secret show \
  --vault-name $(terraform output -raw key_vault_name) \
  --name vault-root-token \
  --query value -o tsv

# Set environment variables and verify
export VAULT_ADDR=$(terraform output -raw vault_addr)
export VAULT_TOKEN=<root_token>
vault status
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `cluster_name` | Unique name prefix for all Azure resources | `string` | — | yes |
| `vault_version` | Vault Enterprise Docker image tag (must be 2.0.0+) | `string` | `"2.0.0-ent"` | no |
| `vault_license` | Vault Enterprise license string | `string` | — | yes |
| `location` | Azure region (e.g. `"East US"`, `"West Europe"`) | `string` | — | yes |
| `resource_group_name` | Existing Resource Group to deploy into | `string` | — | yes |
| `admin_ssh_public_key` | SSH public key string for `azureuser` | `string` | — | yes |
| `vnet_id` | Existing VNet resource ID (`null` = module creates VNet) | `string` | `null` | no |
| `subnet_id` | Existing subnet resource ID (required when `vnet_id` is set) | `string` | `null` | no |
| `vnet_cidr` | Address space for module-managed VNet | `string` | `"10.100.0.0/16"` | no |
| `subnet_cidr` | Address prefix for module-managed subnet | `string` | `"10.100.1.0/24"` | no |
| `vault_ingress_cidr_blocks` | CIDRs allowed inbound on port 8200 | `list(string)` | `["0.0.0.0/0"]` | no |
| `ssh_ingress_cidr_blocks` | CIDRs allowed inbound on port 22 (empty = no SSH rule) | `list(string)` | `[]` | no |
| `vm_size` | Azure VM size | `string` | `"Standard_D2s_v3"` | no |
| `admin_ssh_public_key` | SSH public key for `azureuser` (required by Azure) | `string` | — | yes |
| `os_disk_size_gb` | OS disk size in GiB (Raft storage shares this disk) | `number` | `50` | no |
| `key_vault_name` | Override Key Vault name (≤ 24 chars, globally unique; `null` = auto-derived) | `string` | `null` | no |
| `soft_delete_retention_days` | Soft-delete retention in days (7–90) | `number` | `7` | no |
| `purge_protection_enabled` | Enable Key Vault purge protection (`true` recommended in production) | `bool` | `false` | no |
| `tags` | Additional tags applied to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `vault_addr` | Vault HTTPS address — set as `VAULT_ADDR` |
| `vault_public_ip` | Static public IP of the Vault server |
| `vm_id` | Azure resource ID of the VM |
| `managed_identity_id` | User-assigned managed identity resource ID |
| `managed_identity_principal_id` | Object ID — use when granting additional RBAC roles |
| `managed_identity_client_id` | Client ID of the managed identity |
| `key_vault_id` | Azure Key Vault resource ID |
| `key_vault_uri` | Azure Key Vault URI (e.g. `https://<name>.vault.azure.net/`) |
| `key_vault_name` | Azure Key Vault name |
| `key_vault_root_token_secret_name` | Secret name containing the root token (`vault-root-token`) |
| `vault_tls_cert_host_path` | VM host path to the self-signed TLS cert |
| `vnet_id` | VNet ID used by this deployment |
| `subnet_id` | Subnet ID used by this deployment |

## Networking — BYOVNET

To deploy into an existing VNet, supply both `vnet_id` and `subnet_id`. The module will skip creating a VNet and subnet:

```hcl
module "vault" {
  source = "../../vault_deploy_azure"
  ...
  vnet_id   = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/my-vnet"
  subnet_id = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/my-vnet/subnets/my-subnet"
}
```

## TLS — Self-Signed Certificate

Vault uses a self-signed certificate generated by cloud-init (4096-bit RSA, 10-year validity). The cert includes both the public IP and private IP as SANs.

To avoid `-k` / `VAULT_SKIP_VERIFY=true` on the client:

```bash
# Option 1: copy via SCP (requires SSH access)
scp azureuser@<public_ip>:/opt/vault/certs/vault.crt ./vault.crt
export VAULT_CACERT=./vault.crt

# Option 2: Azure Serial Console / Bastion
# cat /opt/vault/certs/vault.crt  → copy/paste into a local file
```

## Troubleshooting

Cloud-init output is written to `/var/log/vault-cloud-init.log` on the VM. To check progress:

```bash
# SSH (if enabled)
ssh azureuser@<public_ip> "sudo tail -f /var/log/vault-cloud-init.log"

# Azure CLI — serial console output (no SSH required)
az serial-console connect --resource-group <rg> --name <cluster_name>-vault
```

Common issues:
- **403 on Key Vault key creation** — RBAC propagation took longer than 30s; re-run `terraform apply`
- **Vault not ready after 5 min** — check container logs: `docker logs vault` on the VM
- **`purge_protection_enabled = true` blocks destroy** — you must manually purge the Key Vault after deletion: `az keyvault purge --name <name>`

## Production Hardening

- Set `purge_protection_enabled = true` and `soft_delete_retention_days = 90`
- Restrict `vault_ingress_cidr_blocks` to known CIDR ranges
- Replace the self-signed cert with one issued by a trusted CA
- Use Azure Bastion instead of opening SSH (set `ssh_ingress_cidr_blocks = []`)
- Enable Azure Defender for Key Vault

## References

- [Vault Auto-Unseal with Azure Key Vault](https://developer.hashicorp.com/vault/docs/configuration/seal/azurekeyvault)
- [Vault Enterprise Licensing](https://developer.hashicorp.com/vault/docs/enterprise/license)
- [Vault Docker image (`hashicorp/vault-enterprise`)](https://hub.docker.com/r/hashicorp/vault-enterprise)
- [Azure User-Assigned Managed Identity](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/how-manage-user-assigned-managed-identities)
- [Azure Key Vault RBAC guide](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
- [Azure Key Vault REST API — Secrets](https://learn.microsoft.com/en-us/rest/api/keyvault/secrets/set-secret)
- [Azure IMDS — Identity tokens](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/how-to-use-vm-token#get-a-token-using-http)
