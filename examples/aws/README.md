# AWS example

This example is intentionally split into two Terraform configurations:

1. `infra/` deploys `vault_deploy_aws` and `tfe_deploy_aws` into the same VPC, then outputs the SSM paths and connection details needed by the next step.
2. `dynamic/` configures both dynamic credential flows, creates isolated `vault-kv-test` and `aws-creds-test` workspaces, and uploads their test configs to TFE.

Recommended order:

1. Apply `infra/`.
2. Wait for cloud-init to finish before continuing (Vault is usually ready in ~2–3 minutes; TFE commonly takes 10–15 minutes on first boot).
3. Read the Vault root token, Vault TLS cert (base64), and TFE org token from the SSM paths output by `infra/`.
4. Apply `dynamic/`.
5. In the TFE UI, manually queue runs for `vault-kv-test` and `aws-creds-test` after the config uploads complete. The upload step creates configuration versions only; it does **not** auto-queue runs.
