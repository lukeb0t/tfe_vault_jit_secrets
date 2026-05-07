terraform {
  required_version = ">= 1.5.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    # Uncomment when ready to configure TFE workspace variables
    # tfe = {
    #   source  = "hashicorp/tfe"
    #   version = "~> 0.57"
    # }
  }
}
