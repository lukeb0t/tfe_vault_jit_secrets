# Deploys a self-contained Vault Enterprise cluster in Azure.
# The module creates its own VNet, subnet, NSG, Key Vault, and VM.
# To use an existing VNet, pass vnet_id and subnet_id to the module.

module "vault" {
  source = "../../vault_deploy_azure"

  cluster_name        = var.cluster_name
  vault_version       = var.vault_version
  vault_license       = var.vault_license
  location            = var.location
  resource_group_name = var.resource_group_name
  admin_ssh_public_key = var.admin_ssh_public_key

  # Module manages its own VNet/subnet by default.
  # Uncomment to bring your own network:
  # vnet_id   = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>"
  # subnet_id = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"

  vault_ingress_cidr_blocks = ["0.0.0.0/0"] # restrict in production
  ssh_ingress_cidr_blocks   = []             # set your IP to enable SSH, e.g. ["1.2.3.4/32"]
}
