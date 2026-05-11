# ─── Test: Vault-Backed AWS Dynamic Credentials ───────────────────────────────
# This workspace is configured with TFC_VAULT_BACKED_AWS_AUTH=true and the
# jwt-aws-provider backend. TFE exchanges a workload identity JWT for a Vault
# token at the jwt-aws-provider backend, then calls the Vault AWS secrets engine
# to generate short-lived STS credentials, which are injected as standard AWS
# environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN).
#
# Expected result: plan succeeds and outputs the caller identity (assumed-role ARN
# and STS session ID) alongside the available AWS AZs.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# TFE injects AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
# via vault-backed AWS dynamic credentials — no static keys needed.
provider "aws" {
  region = "us-east-1"
}

# Proves STS credentials are valid and shows exactly which role was assumed.
# The ARN will contain "assumed-role/vault-dynamic-creds-target/<session>",
# confirming credentials came from Vault's AWS secrets engine.
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

output "caller_identity" {
  description = "STS caller identity — proves vault-backed assumed-role credentials are in use"
  value = {
    account_id = data.aws_caller_identity.current.account_id
    arn        = data.aws_caller_identity.current.arn
    user_id    = data.aws_caller_identity.current.user_id
  }
}

output "availability_zones" {
  description = "Available AZs in us-east-1 — proves vault-backed AWS STS credentials are working"
  value       = data.aws_availability_zones.available.names
}
