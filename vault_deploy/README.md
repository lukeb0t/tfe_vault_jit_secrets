# vault_deploy

Terraform module that deploys a single-node **Vault Enterprise** server on AWS EC2 using Docker and cloud-init. The instance bootstraps completely automatically — no manual steps, no SSH access required.

## Features

- **Vault Enterprise** running as a Docker container (`hashicorp/vault-enterprise`)
- **AWS KMS auto-unseal** — Vault unseals itself on every (re)start without human intervention ([docs](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms))
- **Raft integrated storage** persisted to an encrypted EBS volume
- **Self-signed TLS** certificate (10-year validity) with the Elastic IP embedded as a Subject Alternative Name
- **Fully automated `vault operator init`** — root token and recovery keys written to SSM Parameter Store as `SecureString` parameters ([docs](https://developer.hashicorp.com/vault/docs/commands/operator/init))
- **IMDSv2 enforced** with hop limit 2 so the Docker container can reach the EC2 instance metadata service (required for KMS credential delivery)
- **SSM Session Manager** access baked in — no key pair or open SSH port required (key pair is optional)

## Usage

```hcl
module "vault" {
  source = "./vault_deploy"

  cluster_name  = "my-vault"
  vault_version = "2.0.0-ent"
  vault_license = var.vault_license   # sensitive — do not hardcode

  vpc_id    = "vpc-xxxxxxxx"
  subnet_id = "subnet-xxxxxxxx"       # must be a public subnet with IGW
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
| `vpc_id` | ID of the VPC where the EC2 instance will be deployed. | `string` | — | ✅ |
| `subnet_id` | ID of a **public** subnet (must have internet gateway route). | `string` | — | ✅ |
| `vault_version` | Docker image tag for `hashicorp/vault-enterprise` (e.g. `2.0.0-ent`). | `string` | `"2.0.0-ent"` | |
| `instance_type` | EC2 instance type. | `string` | `"m5.large"` | |
| `key_pair_name` | Name of an existing EC2 key pair for SSH access. `null` to disable (use SSM instead). | `string` | `null` | |
| `root_volume_size_gb` | Root EBS volume size in GiB. Raft storage shares this volume. | `number` | `50` | |
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
| `iam_role_arn` | ARN of the IAM role attached to the EC2 instance. Pass this to `dynamic_vault_secrets` as `vault_iam_user_arn`. |
| `kms_key_id` | KMS key ID used for auto-unseal. |
| `kms_key_arn` | KMS key ARN used for auto-unseal. |
| `ssm_prefix` | SSM Parameter Store path prefix (`/vault/<cluster_name>`). |
| `ssm_root_token_path` | Full SSM path to the root token (`/vault/<cluster_name>/root_token`). |
| `vault_tls_cert_host_path` | Host path of the self-signed TLS cert. Retrieve via SSM Session Manager and set as `VAULT_CACERT` locally. |

## SSM Parameter Store layout

After successful cloud-init, the following `SecureString` parameters are created:

```
/vault/<cluster_name>/root_token
/vault/<cluster_name>/recovery_key_1
/vault/<cluster_name>/recovery_key_2
/vault/<cluster_name>/recovery_key_3
/vault/<cluster_name>/recovery_key_4
/vault/<cluster_name>/recovery_key_5
```

> **Note:** With KMS auto-unseal, `vault operator init` produces **recovery keys** (not unseal keys). These are used to regenerate a root token if the original is lost. See the [Vault recovery key documentation](https://developer.hashicorp.com/vault/docs/concepts/seal#recovery-key).

## Cloud-init bootstrap sequence

1. Install Docker via `dnf`
2. Query EC2 instance metadata (IMDSv2) for private IP and EIP
3. Create directory layout: `/opt/vault/{data,config,certs}`
4. Set ownership `100:1000` (Vault container UID/GID) on all Vault directories
5. Generate a 10-year self-signed TLS certificate with EIP as SAN
6. Write `vault.hcl` with Raft storage, KMS seal, TLS, and `api_addr`
7. Start Vault container with `--user 100:1000 --entrypoint /bin/vault` (bypasses entrypoint script — see note below)
8. Poll `/v1/sys/health` until Vault responds (up to 5 minutes)
9. Run `vault operator init -recovery-shares=5 -recovery-threshold=3`
10. Store root token and 5 recovery keys in SSM Parameter Store

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
