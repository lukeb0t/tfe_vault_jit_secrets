# ─── Networking ─────────────────────────────────────────────────────────────
# Minimal public VPC for the Vault POC.
# The vault_deploy module requires an existing VPC + public subnet, so we
# create a fresh one here rather than depending on pre-existing networking.

resource "aws_vpc" "vault_poc" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true # required for SSM Session Manager to resolve endpoints

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpc" })
}

resource "aws_internet_gateway" "vault_poc" {
  vpc_id = aws_vpc.vault_poc.id
  tags   = merge(var.tags, { Name = "${var.cluster_name}-igw" })
}

resource "aws_subnet" "vault_public" {
  vpc_id                  = aws_vpc.vault_poc.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true # instance gets a public IP on launch (overridden by EIP)

  tags = merge(var.tags, { Name = "${var.cluster_name}-public-1a" })
}

resource "aws_route_table" "vault_public" {
  vpc_id = aws_vpc.vault_poc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vault_poc.id # default route via IGW
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-public-rt" })
}

resource "aws_route_table_association" "vault_public" {
  subnet_id      = aws_subnet.vault_public.id
  route_table_id = aws_route_table.vault_public.id
}

# ─── Vault Deployment ────────────────────────────────────────────────────────

module "vault" {
  source = "../vault_deploy"

  cluster_name  = var.cluster_name
  vault_version = var.vault_version
  vault_license = var.vault_license

  vpc_id    = aws_vpc.vault_poc.id
  subnet_id = aws_subnet.vault_public.id

  instance_type       = var.instance_type
  root_volume_size_gb = 50

  # Restrict to your source IP in production: e.g. ["203.0.113.0/32"]
  vault_ingress_cidr_blocks = ["0.0.0.0/0"]

  ssm_path_prefix              = "/vault"
  kms_key_deletion_window_days = 7 # short window for lab/POC teardowns

  tags = merge(var.tags, { DeployedBy = "test_deploy" })
}
