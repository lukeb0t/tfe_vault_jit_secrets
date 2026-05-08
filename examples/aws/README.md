# AWS example

This example is split into two Terraform configurations:

1. `infra/` deploys Vault Enterprise and Terraform Enterprise into the same VPC.
2. `dynamic/` configures the Vault dynamic credential modules and creates a demo TFE workspace.

Wait for cloud-init to finish before moving to step 2. Vault is usually ready in a few minutes; TFE commonly takes 10-15 minutes on first boot.
