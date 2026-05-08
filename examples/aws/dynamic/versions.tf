terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.60"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "vault" {
  address         = var.vault_addr
  token           = var.vault_root_token
  skip_tls_verify = true  # self-signed cert from vault_deploy_aws module
}

provider "tfe" {
  hostname        = var.tfe_hostname
  token           = var.tfe_org_token
  ssl_skip_verify = true  # self-signed cert from tfe_deploy_aws module
}
