# Azure example

Deploys a self-contained Vault Enterprise cluster on an Azure Linux VM with its own VNet, Azure Key Vault auto-unseal, and Key Vault-backed secret storage.

```
azure/
├── main.tf                   # Calls vault_deploy_azure
├── variables.tf
├── outputs.tf
├── versions.tf
└── terraform.tfvars.example
```

---

## Modes

### Default mode (`barebones_dev_mode = false`)

Creates the full production-like stack:

| Resource | Purpose |
|---|---|
| Azure Key Vault | Auto-unseal (RSA key) + root token / TLS cert secret storage |
| User-Assigned Managed Identity | Grants the VM access to Key Vault via RBAC |
| Linux VM | Runs Vault Enterprise in Docker with Raft storage |
| VNet + subnet + NSG | Isolated network (or bring your own) |
| Static public IP | Stable `api_addr` for the Vault listener |

Bootstrap secrets written to Key Vault:

| Secret name | Contents |
|---|---|
| `vault-root-token` | Vault root token |
| `vault-tls-cert-b64` | Base64-encoded self-signed Vault TLS certificate |

### Barebones dev mode (`barebones_dev_mode = true`)

Skips Key Vault, managed identity, and RBAC. Vault is initialized with a single Shamir unseal key and the bootstrap credentials are written to `/opt/vault/bootstrap/init.json` on the VM. Intended for short-lived dev/test environments only.

---

## Steps

```bash
cd examples/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set location, resource_group_name, admin_ssh_public_key
export TF_VAR_vault_license="<your Vault Enterprise license>"
terraform init && terraform apply
```

Wait ~3–5 minutes for cloud-init to complete.

### Retrieve the root token (default mode)

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name vault-root-token \
  --query value -o tsv
```

### Retrieve the TLS certificate (default mode)

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name vault-tls-cert-b64 \
  --query value -o tsv | base64 -d > vault.crt
export VAULT_CACERT=vault.crt
```

### Retrieve bootstrap credentials (barebones mode)

SSH into the VM and read the local init file:

```bash
ssh azureuser@$(terraform output -raw vault_public_ip) \
  "sudo cat /opt/vault/bootstrap/init.json"
```

---

## Outputs

| Output | Description |
|---|---|
| `vault_addr` | Vault HTTPS address — set as `VAULT_ADDR` |
| `vault_public_ip` | Static public IP of the VM |
| `key_vault_name` | Azure Key Vault name (default mode only) |
| `key_vault_uri` | Azure Key Vault URI (default mode only) |
| `retrieve_root_token_cmd` | Ready-to-run `az` command to fetch the root token |
| `retrieve_tls_cert_b64_cmd` | Ready-to-run `az` command to fetch the TLS cert |
| `vnet_id` | VNet ID used by this deployment |

---

## Bring your own network

To deploy into an existing VNet, uncomment and populate the `vnet_id` and `subnet_id` inputs in `main.tf`:

```hcl
vnet_id   = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>"
subnet_id = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"
```

---

## Using dynamic secrets with Azure-hosted Vault

The `dynamic_vault_secrets` and `dynamic_aws_provider_secrets` modules are cloud-agnostic. Once this example is applied and Vault is healthy, supply the following to either module:

```hcl
vault_addr       = # terraform output -raw vault_addr
vault_root_token = # az keyvault secret show ... (see above)
vault_ca_cert_b64 = # az keyvault secret show --name vault-tls-cert-b64 ...
tfe_hostname     = # your TFE/HCP Terraform hostname
tfe_org_token    = # your TFE organization API token
tfe_org_name     = # your TFE organization name
```
