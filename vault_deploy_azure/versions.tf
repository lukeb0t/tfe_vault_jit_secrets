terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # time_sleep is used to wait for Azure RBAC propagation before creating
    # the Key Vault key — RBAC assignments can take ~15-30s to take effect.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}
