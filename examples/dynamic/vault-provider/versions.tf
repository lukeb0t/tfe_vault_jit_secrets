terraform {
  required_version = ">= 1.3"

  required_providers {
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

provider "vault" {
  address         = var.vault_addr
  token           = var.vault_root_token
  skip_tls_verify = true # self-signed cert; set VAULT_CACERT or provide vault_ca_cert_b64 instead
}

provider "tfe" {
  hostname        = var.tfe_hostname
  token           = var.tfe_org_token
  ssl_skip_verify = true # set to false if TFE uses a publicly-trusted cert
}
