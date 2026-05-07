#!/bin/bash
# =============================================================================
# Vault Enterprise — cloud-init bootstrap (Azure / Ubuntu 22.04 LTS)
# Cluster : ${cluster_name}
# =============================================================================
# Template variables injected by Terraform's templatefile():
#   cluster_name, vault_version, vault_license, tenant_id,
#   key_vault_name, key_vault_key_name, managed_identity_client_id,
#   vault_api_addr
#
# Key differences from vault_deploy_aws/templates/cloud-init.sh.tpl:
#   - apt-get / docker.io  instead of dnf / docker
#   - dpkg lock wait       instead of immediate package install
#   - Azure IMDS           instead of AWS IMDSv2 (no token exchange needed)
#   - seal "azurekeyvault" instead of seal "awskms"
#   - Azure Key Vault REST API for secret storage instead of AWS SSM
# =============================================================================
set -euo pipefail

# Redirect all output (stdout + stderr) to a persistent log for debugging.
exec > >(tee -a /var/log/vault-cloud-init.log) 2>&1

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "=== Vault cloud-init starting (cluster: ${cluster_name}) ==="

# ─── Terraform-injected values ───────────────────────────────────────────────
# Capture template variables into shell variables immediately so the rest of
# the script only references shell vars (easier to read and debug).
VAULT_VERSION="${vault_version}"
VAULT_LICENSE="${vault_license}"
TENANT_ID="${tenant_id}"
KV_NAME="${key_vault_name}"
KV_KEY_NAME="${key_vault_key_name}"
MI_CLIENT_ID="${managed_identity_client_id}"
# PUBLIC_IP is the static IP pre-allocated by Terraform before this script runs.
PUBLIC_IP="${vault_api_addr}"

# ─── 1. Wait for Ubuntu's unattended-upgrades dpkg lock ──────────────────────
# Ubuntu cloud VMs run unattended-upgrades on first boot, which holds the dpkg
# lock and causes apt-get to fail with "Could not get lock" without this wait.
log "Waiting for dpkg lock to be released..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 3
done
log "dpkg lock released."

# ─── 2. Install dependencies ─────────────────────────────────────────────────
log "Installing system packages..."
apt-get update -y -q
apt-get install -y -q docker.io jq curl openssl

# Enable Docker so it starts automatically after a VM restart.
systemctl enable --now docker
log "Docker started: $(docker --version)"

# ─── 3. Resolve private IP from Azure IMDS ───────────────────────────────────
# Azure IMDS uses a simple header-based request — no token exchange required
# (unlike AWS IMDSv2). The private IP is embedded in the TLS cert SAN and
# vault.hcl cluster_addr so Raft peers can reach each other on port 8201.
log "Fetching private IP from Azure IMDS..."
PRIVATE_IP=$(curl -sf \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2021-02-01&format=text")
log "Private IP: $PRIVATE_IP  |  Public IP (static): $PUBLIC_IP"

# ─── 4. Create directory layout ──────────────────────────────────────────────
# UID 100 / GID 1000 matches the 'vault' user inside the official Docker image.
# All bind-mounted paths must be owned by 100:1000 before the container starts.
log "Creating Vault directory layout..."
mkdir -p /opt/vault/{config,data,certs,logs}
chown -R 100:1000 /opt/vault/data /opt/vault/certs
chmod 755 /opt/vault/{config,data,certs,logs}

# ─── 5. Generate self-signed TLS certificate ─────────────────────────────────
# The cert includes both IPs as SANs and a DNS name so clients can connect
# by IP (external) or hostname (internal) without TLS verification errors.
log "Generating self-signed TLS certificate (valid 10 years)..."
cat > /tmp/vault-openssl.cnf <<SSLCNF
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
CN = vault.${cluster_name}

[v3_req]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = @alt_names

[alt_names]
IP.1  = $PUBLIC_IP
IP.2  = $PRIVATE_IP
IP.3  = 127.0.0.1
DNS.1 = vault.${cluster_name}
DNS.2 = vault.local
SSLCNF

openssl req -x509 -newkey rsa:4096 \
  -keyout /opt/vault/certs/vault.key \
  -out    /opt/vault/certs/vault.crt \
  -days   3650 -nodes \
  -config /tmp/vault-openssl.cnf

chmod 644 /opt/vault/certs/vault.crt
chmod 640 /opt/vault/certs/vault.key  # vault user (UID 100) reads via group 1000
chown 100:1000 /opt/vault/certs/vault.crt /opt/vault/certs/vault.key
rm -f /tmp/vault-openssl.cnf
log "TLS certificate written to /opt/vault/certs/"

# ─── 6. Write vault.hcl ──────────────────────────────────────────────────────
# Uses an unquoted heredoc (<<VAULTCFG) so bash expands $PUBLIC_IP and
# $PRIVATE_IP. All Terraform template variables are already resolved to their
# literal values before this script executes.
log "Writing Vault configuration..."
cat > /opt/vault/config/vault.hcl <<VAULTCFG
# Vault Enterprise — single-node Raft cluster
# Generated by cloud-init on $(date -u '+%Y-%m-%dT%H:%M:%SZ')

ui            = true
disable_mlock = true  # Required: Docker containers cannot raise RLIMIT_MEMLOCK
log_level     = "info"
log_format    = "json"

api_addr     = "https://$PUBLIC_IP:8200"
cluster_addr = "https://$PRIVATE_IP:8201"

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/vault/certs/vault.crt"
  tls_key_file    = "/vault/certs/vault.key"
  tls_min_version = "tls12"
}

# Integrated storage (Raft) — single-node, data persisted on the OS disk.
storage "raft" {
  path    = "/vault/data"
  node_id = "vault-node-1"
}

# Azure Key Vault seal — wraps Vault's master key so the cluster unseals
# automatically on start without operator intervention.
# Equivalent to seal "awskms" in the AWS module.
# client_id selects the specific user-assigned managed identity on the VM.
seal "azurekeyvault" {
  tenant_id  = "$TENANT_ID"
  vault_name = "$KV_NAME"
  key_name   = "$KV_KEY_NAME"
  client_id  = "$MI_CLIENT_ID"
}
VAULTCFG

chown 100:1000 /opt/vault/config/vault.hcl
log "Vault configuration written."

# ─── 7. Write Vault Enterprise license file ──────────────────────────────────
echo "$VAULT_LICENSE" > /opt/vault/config/vault.hclic
chown 100:1000 /opt/vault/config/vault.hclic
chmod 640 /opt/vault/config/vault.hclic

# ─── 8. Start Vault container ─────────────────────────────────────────────────
# --entrypoint /bin/vault : bypasses docker-entrypoint.sh which calls setcap.
#   setcap fails on Azure VMs without CAP_SETFCAP — the same issue as on AWS EC2.
# --user 100:1000         : run as the vault user to match host directory ownership.
# disable_mlock = true    : removes the need for CAP_IPC_LOCK in the container.
# VAULT_LICENSE env var   : passes the license directly; avoids a file bind-mount
#   for the license (kept separate from config for clarity).
log "Starting Vault Enterprise container (version: $VAULT_VERSION)..."
docker run -d \
  --name vault \
  --restart unless-stopped \
  --user 100:1000 \
  --entrypoint /bin/vault \
  -p 8200:8200 \
  -p 8201:8201 \
  -e VAULT_LICENSE="$VAULT_LICENSE" \
  --log-opt max-size=100m \
  --log-opt max-file=3 \
  -v /opt/vault/config:/vault/config:ro \
  -v /opt/vault/data:/vault/data \
  -v /opt/vault/certs:/vault/certs:ro \
  "hashicorp/vault-enterprise:$VAULT_VERSION" \
  server -config=/vault/config/vault.hcl

log "Vault container started. Waiting for API..."

# ─── 9. Wait for Vault API to become available ───────────────────────────────
# Poll /v1/sys/health. Expected responses before init:
#   501 = not initialized (listener is up, not yet init'd)
#   503 = sealed (only possible after a restart, not first boot)
#   200 = active and unsealed
# Any response except connection refused means the listener is ready.
MAX_WAIT=60
for attempt in $(seq 1 $MAX_WAIT); do
  HTTP_STATUS=$(curl -sk -o /dev/null -w "%%{http_code}" \
    "https://127.0.0.1:8200/v1/sys/health" 2>/dev/null || echo "000")

  case "$HTTP_STATUS" in
    200|429|472|473|501|503)
      log "Vault API responding — HTTP $HTTP_STATUS (attempt $attempt)"
      break
      ;;
    *)
      log "Attempt $attempt/$MAX_WAIT — HTTP $HTTP_STATUS, retrying in 5s..."
      sleep 5
      ;;
  esac

  if [ "$attempt" -eq "$MAX_WAIT" ]; then
    log "ERROR: Vault did not become ready after $((MAX_WAIT * 5))s. Container logs:"
    docker logs vault --tail 50
    exit 1
  fi
done

# ─── 10. Initialise Vault ────────────────────────────────────────────────────
# Check whether Vault is already initialized before running init.
# This makes the script idempotent — safe to re-run on VM restart.
INIT_STATUS=$(curl -sk "https://127.0.0.1:8200/v1/sys/init" | jq -r '.initialized')

if [ "$INIT_STATUS" = "false" ]; then
  log "Vault not yet initialized — running 'vault operator init'..."

  # With Azure Key Vault auto-unseal, init produces recovery keys (not unseal keys).
  # Vault automatically unseals using the Azure Key Vault key after init.
  INIT_JSON=$(docker exec \
    -e VAULT_ADDR="https://127.0.0.1:8200" \
    -e VAULT_SKIP_VERIFY="true" \
    vault \
    vault operator init \
      -recovery-shares=5 \
      -recovery-threshold=3 \
      -format=json)

  ROOT_TOKEN=$(echo "$INIT_JSON" | jq -r '.root_token')

  # ─── 11. Store secrets in Azure Key Vault ──────────────────────────────────
  # Obtain an OAuth2 access token for the Key Vault API using the managed
  # identity attached to this VM. The client_id parameter selects the specific
  # user-assigned identity (a VM can have multiple assigned identities).
  log "Fetching Azure Key Vault access token via IMDS..."
  AKV_TOKEN=$(curl -sf \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=$MI_CLIENT_ID" \
    | jq -r '.access_token')

  KV_BASE="https://$KV_NAME.vault.azure.net/secrets"
  API_VER="?api-version=7.3"

  # Helper: write a single secret to Azure Key Vault via the REST API.
  # Equivalent to 'aws ssm put-parameter --type SecureString' in the AWS module.
  store_secret() {
    local name="$1"
    local value="$2"
    curl -sf -X PUT "$KV_BASE/$name$API_VER" \
      -H "Authorization: Bearer $AKV_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"value\": \"$value\"}" > /dev/null
    log "  stored secret: $name"
  }

  store_secret "vault-root-token" "$ROOT_TOKEN"

  # Store all five recovery keys.
  for i in 0 1 2 3 4; do
    KEY=$(echo "$INIT_JSON" | jq -r ".recovery_keys_b64[$i] // empty")
    [ -z "$KEY" ] && continue
    store_secret "vault-recovery-key-$((i + 1))" "$KEY"
  done

  # Clear sensitive values from shell memory.
  unset ROOT_TOKEN INIT_JSON AKV_TOKEN

  log "=== Vault initialized. Secrets stored in Azure Key Vault '$KV_NAME'. ==="
else
  log "Vault already initialized — skipping init."
fi

log "=== Vault cloud-init complete ==="
log "    UI        : https://$PUBLIC_IP:8200/ui"
log "    Root token: az keyvault secret show --vault-name $KV_NAME --name vault-root-token --query value -o tsv"
log "    TLS cert  : /opt/vault/certs/vault.crt  (copy to client as VAULT_CACERT)"
