# Deploy Vault Enterprise — creates its own VPC (10.100.0.0/16)
module "vault" {
  source = "../../../vault_deploy_aws"

  cluster_name       = var.cluster_name
  vault_license      = var.vault_license
  key_pair_name      = var.key_pair_name
  vault_tls_cert_pem = var.vault_tls_cert_pem
  vault_tls_key_pem  = var.vault_tls_key_pem
}
