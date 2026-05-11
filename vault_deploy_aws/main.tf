data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Pick the first available AZ in the region for the managed subnet.
data "aws_availability_zones" "available" {
  state = "available"
}

# Always use the latest Amazon Linux 2023 x86_64 HVM AMI so the instance
# gets current kernel patches without requiring manual AMI ID maintenance.
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  # Strip leading/trailing slashes from ssm_path_prefix then append cluster_name
  # so every deployment gets its own isolated SSM namespace: /vault/<cluster_name>/...
  ssm_prefix = "/${trimsuffix(trimprefix(var.ssm_path_prefix, "/"), "/")}/${var.cluster_name}"

  # When vpc_id is null the module creates its own VPC and subnet.
  # When vpc_id is provided the caller must also supply subnet_id.
  create_networking  = var.vpc_id == null
  vpc_id_resolved    = local.create_networking ? aws_vpc.vault[0].id : var.vpc_id
  subnet_id_resolved = local.create_networking ? aws_subnet.vault_public[0].id : var.subnet_id
  custom_tls_enabled = var.vault_tls_cert_pem != "" && var.vault_tls_key_pem != ""
  barebones_enabled  = var.barebones_dev_mode
  bootstrap_dir      = "/opt/vault/bootstrap"
  kms_enabled        = !local.barebones_enabled

  common_tags = merge(
    {
      Module      = "vault_deploy_aws"
      ClusterName = var.cluster_name
    },
    var.tags
  )
}

# ─── VPC & Networking (managed — only created when vpc_id is not supplied) ────

resource "aws_vpc" "vault" {
  count                = local.create_networking ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for SSM Session Manager endpoint resolution

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vpc" })
}

resource "aws_internet_gateway" "vault" {
  count  = local.create_networking ? 1 : 0
  vpc_id = aws_vpc.vault[0].id
  tags   = merge(local.common_tags, { Name = "${var.cluster_name}-igw" })
}

resource "aws_subnet" "vault_public" {
  count                   = local.create_networking ? 1 : 0
  vpc_id                  = aws_vpc.vault[0].id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-public" })
}

resource "aws_route_table" "vault_public" {
  count  = local.create_networking ? 1 : 0
  vpc_id = aws_vpc.vault[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vault[0].id # default route to internet
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-public-rt" })
}

resource "aws_route_table_association" "vault_public" {
  count          = local.create_networking ? 1 : 0
  subnet_id      = aws_subnet.vault_public[0].id
  route_table_id = aws_route_table.vault_public[0].id
}

# ─── KMS Key for Auto-Unseal ────────────────────────────────────────────────
# Vault uses this key to encrypt/decrypt its master key on every start.
# The key policy grants the account root principal full access, which lets IAM
# policies (below) control actual usage — this is the AWS-recommended pattern.

resource "aws_kms_key" "vault" {
  # Barebones mode uses Shamir unseal, so no KMS key is created.
  count = local.kms_enabled ? 1 : 0

  description             = "Vault auto-unseal key — ${var.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true # rotate the backing key material annually

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableAccountRootAccess"
        Effect = "Allow"
        Principal = {
          # Root access is required so IAM role policies can delegate KMS usage.
          # Without this, even account admins cannot manage the key via IAM.
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vault-unseal" })
}

# Human-readable alias makes it easy to identify the key in the AWS console.
resource "aws_kms_alias" "vault" {
  count = local.kms_enabled ? 1 : 0

  name          = "alias/${var.cluster_name}-vault-unseal"
  target_key_id = aws_kms_key.vault[0].key_id
}

# ─── IAM Role for EC2 Instance Profile ──────────────────────────────────────
# Barebones mode skips IAM entirely. These resources only exist when Vault needs
# KMS auto-unseal, SSM bootstrap storage, or SSM Session Manager access.

resource "aws_iam_role" "vault" {
  count = local.barebones_enabled ? 0 : 1

  name        = "${var.cluster_name}-vault-server"
  description = "Vault EC2 instance role - KMS unseal + SSM init storage"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com" # only EC2 instances can assume this role
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_instance_profile" "vault" {
  count = local.barebones_enabled ? 0 : 1

  name = "${var.cluster_name}-vault-server"
  role = aws_iam_role.vault[0].name
  tags = local.common_tags
}

# Grants the Vault container the minimum KMS permissions needed for auto-unseal.
# Scoped to this deployment's specific KMS key ARN — not account-wide.
resource "aws_iam_role_policy" "vault_kms_unseal" {
  count = local.kms_enabled ? 1 : 0

  name = "kms-auto-unseal"
  role = aws_iam_role.vault[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VaultKMSUnseal"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",          # unwrap the master key on unseal
          "kms:Encrypt",          # wrap the master key on seal
          "kms:DescribeKey",      # validate the key exists and is enabled
          "kms:GenerateDataKey*", # generate data encryption keys
          "kms:ReEncrypt*"        # re-wrap key material under a new key version
        ]
        Resource = aws_kms_key.vault[0].arn
      }
    ]
  })
}

# Grants the cloud-init script permission to write the root token and recovery
# keys to SSM. Scoped to the cluster's SSM prefix path — not all parameters.
resource "aws_iam_role_policy" "vault_ssm_init" {
  # Barebones mode writes init.json locally, so SSM bootstrap writes are skipped.
  count = local.barebones_enabled ? 0 : 1

  name = "ssm-init-secrets"
  role = aws_iam_role.vault[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VaultSSMInitWrite"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter", # write root token + recovery keys on init
          "ssm:GetParameter", # read back to verify (optional but useful)
          "ssm:GetParameters"
        ]
        # Restrict to this cluster's namespace only — no access to other prefixes.
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
      }
    ]
  })
}

# Attaches the AWS-managed policy that enables SSM Session Manager.
# This allows interactive shell sessions without an open SSH port or key pair.
resource "aws_iam_role_policy_attachment" "vault_ssm_session_manager" {
  count = local.barebones_enabled ? 0 : 1

  role       = aws_iam_role.vault[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "vault" {
  name_prefix = "${var.cluster_name}-vault-"
  description = "Controls traffic to/from the Vault server (${var.cluster_name})"
  vpc_id      = local.vpc_id_resolved

  ingress {
    description = "Vault HTTPS API and UI"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = var.vault_ingress_cidr_blocks
  }

  # SSH ingress is omitted entirely when ssh_ingress_cidr_blocks is empty,
  # enforcing SSM-only access by default.
  dynamic "ingress" {
    for_each = length(var.ssh_ingress_cidr_blocks) > 0 ? [1] : []
    content {
      description = "SSH (use SSM Session Manager instead where possible)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_ingress_cidr_blocks
    }
  }

  egress {
    description = "Allow all outbound (KMS, SSM, Docker Hub, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vault" })

  # Ensures the new SG is created before the old one is destroyed during updates,
  # preventing a window where the instance has no security group attached.
  lifecycle {
    create_before_destroy = true
  }
}

# ─── Elastic IP ──────────────────────────────────────────────────────────────
# The EIP is allocated before the instance is created. Terraform passes the EIP's
# public IP into the cloud-init template so Vault's api_addr and TLS SAN are
# correct before the instance even boots — no chicken-and-egg problem.

resource "aws_eip" "vault" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.cluster_name}-vault" })
}

resource "aws_eip_association" "vault" {
  instance_id   = aws_instance.vault.id
  allocation_id = aws_eip.vault.id
}

# ─── EC2 Instance ────────────────────────────────────────────────────────────

resource "aws_instance" "vault" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id_resolved
  vpc_security_group_ids = [aws_security_group.vault.id]
  iam_instance_profile   = local.barebones_enabled ? null : aws_iam_instance_profile.vault[0].name
  key_name               = var.key_pair_name # null = no key pair; use SSM Session Manager

  # Any change to a template variable (version, license, KMS key, etc.) replaces
  # the instance and re-runs the full cloud-init bootstrap automatically.
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/cloud-init.sh.tpl", {
    cluster_name           = var.cluster_name
    vault_version          = var.vault_version
    vault_license          = var.vault_license
    barebones_dev_mode     = local.barebones_enabled ? "true" : "false" # switches cloud-init into local bootstrap mode
    kms_key_id             = local.kms_enabled ? aws_kms_key.vault[0].key_id : ""
    aws_region             = data.aws_region.current.name
    ssm_prefix             = local.barebones_enabled ? "" : local.ssm_prefix # no SSM writes in barebones mode
    vault_api_addr         = aws_eip.vault.public_ip                         # embedded into TLS SAN + Vault api_addr
    vault_use_custom_tls   = local.custom_tls_enabled ? "true" : "false"
    vault_tls_cert_pem_b64 = local.custom_tls_enabled ? base64encode(var.vault_tls_cert_pem) : ""
    vault_tls_key_pem_b64  = local.custom_tls_enabled ? base64encode(var.vault_tls_key_pem) : ""
    bootstrap_dir          = local.bootstrap_dir # local init.json for root token + unseal key
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # enforce IMDSv2; rejects unauthenticated metadata requests

    # Barebones mode never needs container IMDS access; otherwise the Vault
    # container needs hop limit 2 to reach IMDS for AWS IAM credentials.
    http_put_response_hop_limit = local.barebones_enabled ? 1 : 2
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3" # better baseline IOPS (3,000/125 MB/s) than gp2 at same cost
    encrypted             = true  # encrypt Raft data at rest
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vault" })

  lifecycle {
    precondition {
      condition     = !var.barebones_dev_mode || (var.key_pair_name != null && var.key_pair_name != "")
      error_message = "barebones_dev_mode requires key_pair_name so you can SSH in and retrieve the bootstrap credentials."
    }

    precondition {
      condition     = !var.barebones_dev_mode || length(var.ssh_ingress_cidr_blocks) > 0
      error_message = "barebones_dev_mode requires at least one SSH ingress CIDR block."
    }

    precondition {
      condition = (
        (var.vault_tls_cert_pem == "" && var.vault_tls_key_pem == "") ||
        (var.vault_tls_cert_pem != "" && var.vault_tls_key_pem != "")
      )
      error_message = "vault_tls_cert_pem and vault_tls_key_pem must both be set together, or both left empty."
    }
  }
}
