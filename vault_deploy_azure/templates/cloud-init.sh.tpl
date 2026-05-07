#!/bin/bash
# cloud-init bootstrap for Vault Enterprise on Azure (Ubuntu 22.04 LTS)
# Template variables are rendered by Terraform's templatefile() function.
# Equivalent to vault_deploy_aws/templates/cloud-init.sh.tpl but uses:
#   - apt instead of dnf/yum
#   - Azure Key Vault REST API instead of AWS SSM Parameter Store
#   - seal "azurekeyvault" instead of seal "awskms"
#   - Azure IMDS instead of AWS IMDS

set -euxo pipefail
exec > >(tee /var/log/vault-init.log) 2>&1

# ─── 1. Wait for Ubuntu's unattended-upgrades dpkg lock ──────────────────────
# Ubuntu cloud VMs run unattended-upgrades on first boot, which holds the
# dpkg lock and will cause apt-get to fail without this wait.
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "Waiting for dpkg lock to be released..."
  sleep 5
done

# ─── 2. Install dependencies ─────────────────────────────────────────────────
apt-get update -y
apt-get install -y docker.io jq curl openssl unzip awscli

# Enable Docker so it survives a VM restart.
systemctl enable docker
systemctl start docker

# ─── 3. Resolve network addresses from Azure IMDS ────────────────────────────
# Azure IMDS requires the Metadata header — unlike AWS IMDS there is no IMDSv2
# token exchange. The private IP is embedded into the TLS cert SAN and vault.hcl.
PRIVATE_IP=$(curl -sf \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2021-02-01&format=text")

# The public IP is known before cloud-init runs — Terraform pre-allocates
# a Static Standard public IP and passes it to templatefile().
PUBLIC_IP="${vault_api_addr}"

# ─── 4. Create directory layout ──────────────────────────────────────────────
# UID 100 / GID 1000 matches the 'vault' user inside the official Docker image.
mkdir -p /opt/vault/{data,certs,config,plugins,logs}
chown -R 100:1000 /opt/vault

# ─── 5. Generate self-signed TLS certificate ─────────────────────────────────
# The cert includes both the public IP (for external API/UI access) and the
# private IP (for internal cluster communication).
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /opt/vault/certs/vault.key \
  -out    /opt/vault/certs/vault.crt \
  -days   365 \
  -subj   "/CN=${cluster_name}-vault" \
  -addext "subjectAltName=IP:$${PUBLIC_IP},IP:$${PRIVATE_IP},IP:127.0.0.1"

# Vault container (UID 100) must be able to read the key.
chown -R 100:1000 /opt/vault/certs
chmod 640 /opt/vault/certs/vault.key

# ─── 6. Write vault.hcl ──────────────────────────────────────────────────────
cat > /opt/vault/config/vault.hcl <<'VAULTCFG'
# Integrated storage (Raft) — single-node cluster backed by the OS disk.
storage "raft" {
  path    = "/vault/data"
  node_id = "${cluster_name}"
}

listener "tcp" {
  address            = "0.0.0.0:8200"
  tls_cert_file      = "/vault/certs/vault.crt"
  tls_key_file       = "/vault/certs/vault.key"
}

# Azure Key Vault seal — wraps Vault's master key with the Azure Key Vault key.
# Equivalent to seal "awskms" in the AWS module.
# The managed identity (user-assigned) authenticates to Azure Key Vault
# using its client_id obtained from the Azure IMDS.
seal "azurekeyvault" {
  tenant_id      = "${tenant_id}"
  vault_name     = "${key_vault_name}"
  key_name       = "${key_vault_key_name}"
  client_id      = "${managed_identity_client_id}"
}

# api_addr is the public IP — used in redirect responses so CLI/SDK clients
# follow HA leader redirects to the correct endpoint.
api_addr     = "https://$${PUBLIC_IP}:8200"
cluster_addr = "https://$${PRIVATE_IP}:8201"

disable_mlock = true  # Required: Docker containers cannot raise RLIMIT_MEMLOCK
ui            = true  # Enable the Vault Web UI at https://<public_ip>:8200/ui
VAULTCFG

chown 100:1000 /opt/vault/config/vault.hcl

# ─── 7. Write Vault Enterprise license file ──────────────────────────────────
echo "${vault_license}" > /opt/vault/config/vault.hclic
chown 100:1000 /opt/vault/config/vault.hclic
chmod 640 /opt/vault/config/vault.hclic

# ─── 8. Start Vault container ─────────────────────────────────────────────────
# --entrypoint / --user: docker-entrypoint.sh calls setcap which fails on
# standard EC2/Azure VMs without NET_ADMIN capability.  Bypassing the entrypoint
# and running as vault UID (100) with disable_mlock=true avoids both issues.
docker run -d \
  --name vault \
  --restart unless-stopped \
  --cap-add IPC_LOCK \
  --entrypoint /bin/vault \
  --user 100:1000 \
  -p 8200:8200 \
  -p 8201:8201 \
  -v /opt/vault/data:/vault/data \
  -v /opt/vault/certs:/vault/certs:ro \
  -v /opt/vault/config:/vault/config:ro \
  -v /opt/vault/plugins:/vault/plugins \
  -v /opt/vault/logs:/vault/logs \
  -e VAULT_LICENSE_PATH=/vault/config/vault.hclic \
  hashicorp/vault-enterprise:${vault_version} \
  server -config=/vault/config/vault.hcl

# ─── 9. Wait for Vault to become ready ───────────────────────────────────────
# Poll until Vault returns a recognisable HTTP response.
# At this point it will return 501 (not initialised) or 503 (sealed) —
# both indicate the listener is up.
echo "Waiting for Vault API to become available..."
for i in $(seq 1 60); do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%%{http_code}" https://127.0.0.1:8200/v1/sys/health || true)
  if [[ "$HTTP_CODE" == "501" || "$HTTP_CODE" == "503" || "$HTTP_CODE" == "200" ]]; then
    echo "Vault API ready (HTTP $HTTP_CODE)"
    break
  fi
  echo "  attempt $i — HTTP $HTTP_CODE, retrying in 5s..."
  sleep 5
done

# ─── 10. Initialise Vault ────────────────────────────────────────────────────
# With KMS auto-unseal, 'vault operator init' produces recovery keys (not
# unseal keys). Vault automatically unseals using the Key Vault key.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_SKIP_VERIFY="true"

INIT_OUTPUT=$(docker exec \
  -e VAULT_ADDR=https://127.0.0.1:8200 \
  -e VAULT_SKIP_VERIFY=true \
  vault /bin/vault operator init \
    -recovery-shares=5 \
    -recovery-threshold=3 \
    -format=json)

ROOT_TOKEN=$(echo "$INIT_OUTPUT"    | jq -r '.root_token')
RECOVERY_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.recovery_keys_b64[0]')
RECOVERY_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.recovery_keys_b64[1]')
RECOVERY_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.recovery_keys_b64[2]')
RECOVERY_KEY_4=$(echo "$INIT_OUTPUT" | jq -r '.recovery_keys_b64[3]')
RECOVERY_KEY_5=$(echo "$INIT_OUTPUT" | jq -r '.recovery_keys_b64[4]')

# ─── 11. Store secrets in Azure Key Vault ────────────────────────────────────
# Use the managed identity to obtain a token from Azure IMDS, then store
# secrets via the Azure Key Vault REST API.
# Equivalent to the SSM Parameter Store SecureString writes in the AWS module.

# Fetch an access token scoped to Azure Key Vault using the managed identity.
# The client_id selects the specific user-assigned identity (a VM may have several).
IMDS_TOKEN=$(curl -sf \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=${managed_identity_client_id}" \
  | jq -r '.access_token')

KV_BASE="https://${key_vault_name}.vault.azure.net/secrets"
API_VER="?api-version=7.3"

store_secret() {
  local name="$1"
  local value="$2"
  curl -sf -X PUT "$${KV_BASE}/$${name}$${API_VER}" \
    -H "Authorization: Bearer $${IMDS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"value\": \"$${value}\"}" > /dev/null
  echo "Stored secret: $${name}"
}

store_secret "vault-root-token"  "$${ROOT_TOKEN}"
store_secret "vault-recovery-key-1" "$${RECOVERY_KEY_1}"
store_secret "vault-recovery-key-2" "$${RECOVERY_KEY_2}"
store_secret "vault-recovery-key-3" "$${RECOVERY_KEY_3}"
store_secret "vault-recovery-key-4" "$${RECOVERY_KEY_4}"
store_secret "vault-recovery-key-5" "$${RECOVERY_KEY_5}"

echo "Vault bootstrap complete. Root token stored in Azure Key Vault secret 'vault-root-token'."
echo "  Key Vault: https://${key_vault_name}.vault.azure.net/"
echo "  Vault UI:  https://$${PUBLIC_IP}:8200/ui"
