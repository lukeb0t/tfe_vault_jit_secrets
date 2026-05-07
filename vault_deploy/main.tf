data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

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
  # Normalise the SSM prefix and append the cluster name so each deployment
  # gets its own isolated parameter namespace: /vault/<cluster_name>/...
  ssm_prefix = "/${trimsuffix(trimprefix(var.ssm_path_prefix, "/"), "/")}/${var.cluster_name}"

  common_tags = merge(
    {
      Module      = "vault_deploy"
      ClusterName = var.cluster_name
    },
    var.tags
  )
}

# ─── KMS Key for Auto-Unseal ────────────────────────────────────────────────
# The key policy grants the account root full access (which delegates to IAM).
# Actual usage rights are enforced via the Vault instance's IAM role policy below.

resource "aws_kms_key" "vault" {
  description             = "Vault auto-unseal key — ${var.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableAccountRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vault-unseal" })
}

resource "aws_kms_alias" "vault" {
  name          = "alias/${var.cluster_name}-vault-unseal"
  target_key_id = aws_kms_key.vault.key_id
}

# ─── IAM Role for EC2 Instance Profile ──────────────────────────────────────

resource "aws_iam_role" "vault" {
  name        = "${var.cluster_name}-vault-server"
  description = "Vault EC2 instance role - KMS unseal + SSM init storage"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_instance_profile" "vault" {
  name = "${var.cluster_name}-vault-server"
  role = aws_iam_role.vault.name
  tags = local.common_tags
}

# Allow Vault container to use the KMS key for auto-unseal
resource "aws_iam_role_policy" "vault_kms_unseal" {
  name = "kms-auto-unseal"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VaultKMSUnseal"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = aws_kms_key.vault.arn
      }
    ]
  })
}

# Allow cloud-init to write the root token and recovery keys to SSM
resource "aws_iam_role_policy" "vault_ssm_init" {
  name = "ssm-init-secrets"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VaultSSMInitWrite"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
      }
    ]
  })
}

# SSM Session Manager — allows SSH-less access to the instance for troubleshooting
resource "aws_iam_role_policy_attachment" "vault_ssm_session_manager" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "vault" {
  name_prefix = "${var.cluster_name}-vault-"
  description = "Controls traffic to/from the Vault server (${var.cluster_name})"
  vpc_id      = var.vpc_id

  ingress {
    description = "Vault HTTPS API and UI"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = var.vault_ingress_cidr_blocks
  }

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

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Elastic IP ──────────────────────────────────────────────────────────────
# Allocated before the instance so its address can be embedded in cloud-init
# (Vault api_addr and the TLS SAN both use the public IP).

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
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.vault.id]
  iam_instance_profile   = aws_iam_instance_profile.vault.name
  key_name               = var.key_pair_name

  # Changing any template variable forces a new instance + re-initialisation
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/cloud-init.sh.tpl", {
    cluster_name   = var.cluster_name
    vault_version  = var.vault_version
    vault_license  = var.vault_license
    kms_key_id     = aws_kms_key.vault.key_id
    aws_region     = data.aws_region.current.name
    ssm_prefix     = local.ssm_prefix
    vault_api_addr = aws_eip.vault.public_ip
  })

  # IMDSv2 required; hop limit of 2 allows the Docker container to reach the
  # metadata service for IAM credential delivery (needed for KMS auto-unseal).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vault" })
}
