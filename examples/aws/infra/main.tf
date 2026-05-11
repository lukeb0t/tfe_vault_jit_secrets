# Deploy Vault Enterprise — creates its own VPC (10.100.0.0/16)
module "vault" {
  source = "../../../vault_deploy_aws"

  cluster_name       = var.cluster_name
  vault_license      = var.vault_license
  key_pair_name      = var.key_pair_name
  vault_tls_cert_pem = var.vault_tls_cert_pem
  vault_tls_key_pem  = var.vault_tls_key_pem
  # Default CIDR 10.100.0.0/16 — TFE will join this VPC
}

# Deploy TFE — joins Vault's VPC so they can communicate
module "tfe" {
  source = "../../../tfe_deploy_aws"

  cluster_name      = "${var.cluster_name}-tfe"
  tfe_license       = var.tfe_license
  admin_email       = var.admin_email
  admin_password    = var.admin_password
  org_name          = var.tfe_org_name
  key_pair_name     = var.key_pair_name
  # Explicit bool avoids "count depends on unknown value" error when vpc_id comes from module output.
  create_networking = false

  # Deploy into Vault's VPC — enables direct communication between Vault and TFE
  vpc_id    = module.vault.vpc_id
  subnet_id = module.vault.subnet_id
}

# Allow TFE → Vault on port 8200 (Vault API). Vault reaches TFE over the VPC
# using its own outbound access, so Vault does not need an inbound 443 rule here.
resource "aws_security_group_rule" "vault_from_tfe" {
  type                     = "ingress"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  source_security_group_id = module.tfe.security_group_id # restrict to TFE's SG only
  security_group_id        = module.vault.security_group_id
  description              = "Allow TFE to reach Vault API for dynamic credentials"
}
