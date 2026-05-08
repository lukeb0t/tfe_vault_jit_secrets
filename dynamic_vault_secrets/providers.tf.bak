provider "vault" {
  address = var.vault_addr
  token   = var.vault_token

  # Required when Vault uses a self-signed certificate.
  # Set VAULT_CACERT or VAULT_SKIP_VERIFY as an alternative.
  ca_cert_file = var.vault_ca_cert_file != "" ? var.vault_ca_cert_file : null
}

provider "tfe" {
  hostname = var.tfe_hostname
  token    = var.tfe_token
}
