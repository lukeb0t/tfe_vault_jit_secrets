# Minimal example: deploy Vault Enterprise with a fully managed VPC.
# The vault_deploy_aws module creates all networking automatically.
# To use an existing VPC, add: vpc_id = "vpc-xxx" and subnet_id = "subnet-xxx"

module "vault" {
  source = "../../vault_deploy_aws"

  cluster_name  = var.cluster_name
  vault_version = var.vault_version
  vault_license = var.vault_license

  # Networking is created automatically — override vpc_cidr/subnet_cidr if needed.
  # vpc_cidr    = "10.100.0.0/16"
  # subnet_cidr = "10.100.1.0/24"

  # Restrict to your source IP in production: e.g. ["203.0.113.0/32"]
  vault_ingress_cidr_blocks = ["0.0.0.0/0"]

  kms_key_deletion_window_days = 7 # short window for lab teardowns

  tags = { DeployedBy = "examples/aws" }
}
