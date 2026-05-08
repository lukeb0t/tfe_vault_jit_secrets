# Deploy Vault Enterprise — creates its own VPC (10.100.0.0/16)
module "vault" {
  source = "../../../vault_deploy_aws"

  cluster_name  = var.cluster_name
  vault_license = var.vault_license
  key_pair_name = var.key_pair_name
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
  create_networking = false   # join Vault's VPC; explicit bool avoids plan-time count error

  # Deploy into Vault's VPC — enables direct communication between Vault and TFE
  vpc_id    = module.vault.vpc_id
  subnet_id = module.vault.subnet_id
}

# Allow TFE → Vault on port 8200 (Vault API) and 443 (OIDC discovery endpoint on Vault is not needed — Vault reaches TFE)
resource "aws_security_group_rule" "vault_from_tfe" {
  type                     = "ingress"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  source_security_group_id = module.tfe.security_group_id
  security_group_id        = module.vault.security_group_id
  description              = "Allow TFE to reach Vault API for dynamic credentials"
}
