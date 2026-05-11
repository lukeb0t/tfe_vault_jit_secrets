# vault_deploy_aws

Terraform module that deploys a single-node **Vault Enterprise** server on AWS EC2 using Docker and cloud-init. The instance bootstraps completely automatically — no manual steps, no SSH access required.

## Features

- **Vault Enterprise** running as a Docker container (`hashicorp/vault-enterprise`)
- **AWS KMS auto-unseal** — Vault unseals itself on every (re)start without human intervention ([docs](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms))
- **Raft integrated storage** persisted to an encrypted EBS volume
- **TLS certificate options** — auto-generated self-signed cert by default, or supply your own cert/key PEM
- **Fully automated `vault operator init`** — root token and recovery keys written to SSM Parameter Store as `SecureString` parameters ([docs](https://developer.hashicorp.com/vault/docs/commands/operator/init))
- **Barebones dev mode** — disables KMS auto-unseal, IAM, and SSM bootstrap storage, then writes a single-share Shamir init file locally for SSH retrieval
- **IMDSv2 enforced** with hop limit 2 so the Docker container can reach the EC2 instance metadata service (required for KMS credential delivery)
- **SSM Session Manager** access baked in — no key pair or open SSH port required (key pair is optional)

## Usage

```hcl
module "vault" {
  source = "./vault_deploy_aws"

  cluster_name  = "my-vault"
  vault_version = "2.0.0-ent"
  vault_license = var.vault_license   # sensitive — do not hardcode

   # Optional: omit these to let the module create its own VPC + public subnet.
   vpc_id    = "vpc-xxxxxxxx"
   subnet_id = "subnet-xxxxxxxx"      # must be a public subnet with IGW

   # Optional: use barebones dev mode for local bootstrap retrieval over SSH.
   # barebones_dev_mode = true
   # key_pair_name      = "my-keypair"
 }
 ```

After `terraform apply` completes (~2 minutes for cloud-init), retrieve the root token:

```bash
# Using the module output
aws ssm get-parameter \
  --name "$(terraform output -raw ssm_root_token_path)" \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value --output text

# Or directly
aws ssm get-parameter \
  --name "/vault/my-vault/root_token" \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value --output text
```

Verify Vault is healthy:

```bash
curl -sk "$(terraform output -raw vault_addr)/v1/sys/health" | jq .
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| hashicorp/aws | ~> 5.0 |

### IAM permissions required by the caller

The principal running Terraform needs:

- `ec2:*` (instance, security group, EIP, AMI lookup)
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:CreateInstanceProfile`, `iam:PassRole`
- `kms:CreateKey`, `kms:CreateAlias`, `kms:PutKeyPolicy`, `kms:ScheduleKeyDeletion`

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `cluster_name` | Unique name prefix applied to all resources (e.g. `my-vault`). | `string` | — | ✅ |
| `vault_license` | Vault Enterprise license string. Passed to the container as `VAULT_LICENSE`. | `string` (sensitive) | — | ✅ |
| `vpc_id` | ID of an existing VPC. Leave `null` to let the module create one. | `string` | `null` | |
| `subnet_id` | ID of an existing **public** subnet. Required only when `vpc_id` is set. | `string` | `null` | |
| `vpc_cidr` | CIDR block for a module-managed VPC. Used only when `vpc_id = null`. | `string` | `"10.100.0.0/16"` | |
| `subnet_cidr` | CIDR block for a module-managed public subnet. Used only when `vpc_id = null`. | `string` | `"10.100.1.0/24"` | |
| `vault_version` | Docker image tag for `hashicorp/vault-enterprise` (e.g. `2.0.0-ent`). | `string` | `"2.0.0-ent"` | |
| `instance_type` | EC2 instance type. | `string` | `"m5.large"` | |
| `barebones_dev_mode` | Disable KMS auto-unseal, IAM, and SSM bootstrap storage; use local Shamir bootstrap files instead. | `bool` | `false` | |
| `key_pair_name` | Name of an existing EC2 key pair for SSH access. Required when `barebones_dev_mode = true`. | `string` | `null` | |
| `root_volume_size_gb` | Root EBS volume size in GiB. Raft storage shares this volume. | `number` | `50` | |
| `vault_tls_cert_pem` | Optional PEM-encoded TLS cert for Vault listener (`""` = generate self-signed cert). | `string` | `""` | |
| `vault_tls_key_pem` | Optional PEM-encoded private key for `vault_tls_cert_pem` (`""` = generate self-signed key). | `string` | `""` | |
| `vault_ingress_cidr_blocks` | CIDRs allowed to reach Vault on port 8200. | `list(string)` | `["0.0.0.0/0"]` | |
| `ssh_ingress_cidr_blocks` | CIDRs allowed to SSH on port 22. Set to `[]` to disable. | `list(string)` | `[]` | |
| `kms_key_deletion_window_days` | Days before KMS key is permanently deleted after `terraform destroy` (7–30). | `number` | `30` | |
| `ssm_path_prefix` | Leading SSM path segment. Cluster name is appended automatically. | `string` | `"/vault"` | |
| `tags` | Additional tags merged onto all resources. | `map(string)` | `{}` | |

## Outputs

| Name | Description |
|------|-------------|
| `vault_addr` | HTTPS address of the Vault server (use as `VAULT_ADDR`). |
| `vault_public_ip` | Elastic IP address assigned to the Vault server. |
| `instance_id` | EC2 instance ID. |
| `security_group_id` | Security group ID. |
| `iam_role_arn` | ARN of the IAM role attached to the EC2 instance (null in barebones mode). Pass this to `dynamic_aws_provider_secrets` as `vault_iam_user_arn`. |
| `kms_key_id` | KMS key ID used for auto-unseal. |
| `kms_key_arn` | KMS key ARN used for auto-unseal. |
| `ssm_prefix` | SSM Parameter Store path prefix (`/vault/<cluster_name>`). |
| `ssm_root_token_path` | Full SSM path to the root token (`/vault/<cluster_name>/root_token`). |
| `ssm_tls_cert_b64_path` | Full SSM path to the base64-encoded Vault TLS cert (`/vault/<cluster_name>/tls_cert_b64`). Useful for `vault_ca_cert_b64`. |
| `barebones_bootstrap_file` | Local init JSON file containing the root token and unseal key when barebones dev mode is enabled. |
| `vault_tls_cert_host_path` | Host path of the self-signed TLS cert. Retrieve via SSM Session Manager and set as `VAULT_CACERT` locally. |
| `vpc_id` | VPC ID used by this deployment. |
| `subnet_id` | Public subnet ID used by this deployment. |

## SSM Parameter Store layout

After successful cloud-init, the following `SecureString` parameters are created:

```
/vault/<cluster_name>/tls_cert_b64
/vault/<cluster_name>/root_token
/vault/<cluster_name>/recovery_key_1
/vault/<cluster_name>/recovery_key_2
/vault/<cluster_name>/recovery_key_3
/vault/<cluster_name>/recovery_key_4
/vault/<cluster_name>/recovery_key_5
```

> **Note:** With KMS auto-unseal, `vault operator init` produces **recovery keys** (not unseal keys). These are used to regenerate a root token if the original is lost. See the [Vault recovery key documentation](https://developer.hashicorp.com/vault/docs/concepts/seal#recovery-key).

In `barebones_dev_mode`, no IAM role/profile is attached and no SSM parameters are written. Instead, cloud-init writes `/opt/vault/bootstrap/init.json` with the root token and single Shamir unseal key.

## Cloud-init bootstrap sequence

1. Install Docker via `dnf`
2. Query EC2 instance metadata (IMDSv2) for private IP and EIP
3. Create directory layout: `/opt/vault/{data,config,certs}`
4. Set ownership `100:1000` (Vault container UID/GID) on all Vault directories
5. Prepare TLS cert/key: either provide your own PEM-encoded cert/key via `vault_tls_cert_pem` and `vault_tls_key_pem`, or cloud-init generates a 10-year self-signed cert with the EIP as SAN
6. Write `vault.hcl` with Raft storage, KMS seal, TLS, and `api_addr`
7. Start Vault container with `--user 100:1000 --entrypoint /bin/vault` (bypasses entrypoint script — see note below)
8. Poll `/v1/sys/health` until Vault responds (up to 5 minutes)
9. Run `vault operator init -recovery-shares=5 -recovery-threshold=3` (or `-key-shares=1 -key-threshold=1` in barebones mode)
10. Store bootstrap data in SSM Parameter Store, or write `/opt/vault/bootstrap/init.json` in barebones mode

## TLS Certificate Configuration

By default, Vault uses a self-signed certificate generated by cloud-init (4096-bit RSA, 10-year validity) with the EIP as SAN.

To provide your own certificate/key:

```hcl
module "vault" {
  source = "../../vault_deploy_aws"
  # ...
  vault_tls_cert_pem = file("${path.module}/certs/vault.crt")
  vault_tls_key_pem  = file("${path.module}/certs/vault.key")
}
```

When using custom TLS material, ensure the certificate SAN/CN matches how clients connect to Vault (for example, public IP or DNS name).

> **Why `--entrypoint /bin/vault`?** Vault 2.0's `docker-entrypoint.sh` calls `setcap cap_ipc_lock` on the vault binary. This requires `CAP_SETFCAP` in the effective capability set, which EC2 instances do not grant even with `--cap-add SETFCAP`. Since `disable_mlock = true` is set in `vault.hcl`, memory locking is not needed anyway. Bypassing the entrypoint avoids the crash entirely.

## Troubleshooting

Check the cloud-init log via SSM Session Manager:

```bash
# Open an SSM session
aws ssm start-session --target <instance_id> --region us-east-1

# Inside the session
sudo tail -f /var/log/vault-cloud-init.log
sudo docker ps -a
sudo docker logs vault 2>&1 | tail -50
```

Verify Vault status:

```bash
export VAULT_ADDR=https://<eip>:8200
export VAULT_SKIP_VERIFY=true   # for self-signed TLS
vault status
```

## References

- [Vault Auto-unseal using AWS KMS](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms)
- [Vault Integrated Storage (Raft)](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- [vault operator init](https://developer.hashicorp.com/vault/docs/commands/operator/init)
- [Vault Recovery Keys](https://developer.hashicorp.com/vault/docs/concepts/seal#recovery-key)
- [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Vault Enterprise Docker image](https://hub.docker.com/r/hashicorp/vault-enterprise)
