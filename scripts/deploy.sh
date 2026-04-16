#!/usr/bin/env bash
# Deploy NemoClaw on Azure (interactive-friendly).
# Prompts for any required inputs that weren't supplied on the command line.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [options]

All inputs are optional; missing values are prompted for interactively.

  --subscription-id ID      Azure subscription to deploy into
  --resource-group NAME     Resource group (created if missing)
  --location REGION         Default: centralus
  --ssh-public-key STRING   Contents of your SSH public key
  --nvidia-api-key KEY      NVIDIA API key (or set NVIDIA_API_KEY env var)
  --allowed-ssh-cidr CIDR   Default: detected public IP /32, or 0.0.0.0/0
  --name-prefix NAME        Default: nemoclaw
  --vm-size SIZE            Default: Standard_D4s_v4
  --admin-username NAME     Default: azureuser
  --assistant-name NAME     Default: my-assistant
  --os-disk-size-gb N       Default: 64
EOF
}

SUB_ID=""
RG=""
LOCATION="centralus"
SSH_KEY=""
NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
SSH_CIDR=""
PREFIX="nemoclaw"
VM_SIZE="Standard_D4s_v4"
ADMIN="azureuser"
ASSISTANT="my-assistant"
OS_DISK=64

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id)   SUB_ID="$2"; shift 2 ;;
    --resource-group)    RG="$2"; shift 2 ;;
    --location)          LOCATION="$2"; shift 2 ;;
    --ssh-public-key)    SSH_KEY="$2"; shift 2 ;;
    --nvidia-api-key)    NVIDIA_API_KEY="$2"; shift 2 ;;
    --allowed-ssh-cidr)  SSH_CIDR="$2"; shift 2 ;;
    --name-prefix)       PREFIX="$2"; shift 2 ;;
    --vm-size)           VM_SIZE="$2"; shift 2 ;;
    --admin-username)    ADMIN="$2"; shift 2 ;;
    --assistant-name)    ASSISTANT="$2"; shift 2 ;;
    --os-disk-size-gb)   OS_DISK="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

prompt_required() {
  local var_name="$1" prompt="$2" current="${!1}"
  while [[ -z "$current" ]]; do
    read -r -p "$prompt: " current
    current="${current## }"; current="${current%% }"
  done
  printf -v "$var_name" '%s' "$current"
}

# ---------- Subscription ----------
if [[ -z "$SUB_ID" ]]; then
  echo
  echo "Azure subscriptions:"
  az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o table
  prompt_required SUB_ID "  Subscription ID"
fi

# ---------- Resource group ----------
prompt_required RG "Resource group name (will be created if missing)"

# ---------- SSH key ----------
if [[ -z "$SSH_KEY" ]]; then
  for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$candidate" ]]; then
      SSH_KEY="$(< "$candidate")"
      echo "Using SSH public key from $candidate"
      break
    fi
  done
fi
if [[ -z "$SSH_KEY" ]]; then
  echo "No SSH key found. Generate one with:  ssh-keygen -t ed25519 -C 'nemoclaw'"
  prompt_required SSH_KEY "Paste your SSH public key contents"
fi

# ---------- NVIDIA API key (optional) ----------
if [[ -z "$NVIDIA_API_KEY" ]]; then
  echo
  echo "NVIDIA API key (from https://build.nvidia.com/) — used for routed inference."
  echo "Leave blank to skip; you will need to run 'nemoclaw onboard' manually on the VM."
  read -r -p "  NVIDIA API key (optional): " NVIDIA_API_KEY || true
fi

# ---------- SSH CIDR ----------
if [[ -z "$SSH_CIDR" ]]; then
  MY_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$MY_IP" ]]; then
    read -r -p "Detected public IP $MY_IP. Restrict SSH to $MY_IP/32 ? [Y/n]: " ans || true
    if [[ "$ans" =~ ^[Nn] ]]; then SSH_CIDR="0.0.0.0/0"; else SSH_CIDR="$MY_IP/32"; fi
  else
    read -r -p "CIDR allowed to reach SSH [0.0.0.0/0]: " SSH_CIDR || true
    SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"
  fi
fi

# ---------- Subscription select ----------
echo
echo "==> Selecting subscription $SUB_ID"
az account set --subscription "$SUB_ID"
ACCT_NAME="$(az account show --query name -o tsv)"
echo "   Using: $ACCT_NAME ($SUB_ID)"

# ---------- Deploy ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../infra/main.bicep"

echo "==> Ensuring resource group $RG ($LOCATION)"
az group create --name "$RG" --location "$LOCATION" --output none

DEPLOYMENT_NAME="nemoclaw-$(date +%Y%m%d%H%M%S)"
echo "==> Deploying $DEPLOYMENT_NAME (this takes ~2-4 minutes for infra)"

if ! az deployment group create \
      --resource-group "$RG" \
      --name "$DEPLOYMENT_NAME" \
      --template-file "$TEMPLATE" \
      --parameters \
          namePrefix="$PREFIX" \
          location="$LOCATION" \
          vmSize="$VM_SIZE" \
          adminUsername="$ADMIN" \
          sshPublicKey="$SSH_KEY" \
          allowedSshCidr="$SSH_CIDR" \
          nvidiaApiKey="$NVIDIA_API_KEY" \
          assistantName="$ASSISTANT" \
          osDiskSizeGB="$OS_DISK" \
      --output json > /tmp/nemoclaw-deploy.json; then
  echo
  echo "❌ Deployment FAILED."
  echo "   Inspect errors with:"
  echo "     az deployment group show -g $RG -n $DEPLOYMENT_NAME --query properties.error"
  echo "     az deployment operation group list -g $RG -n $DEPLOYMENT_NAME \\"
  echo "       --query \"[?properties.provisioningState=='Failed']\""
  exit 1
fi

IP=$(jq -r '.properties.outputs.publicIpAddress.value' /tmp/nemoclaw-deploy.json)
SSH_CMD=$(jq -r '.properties.outputs.sshCommand.value' /tmp/nemoclaw-deploy.json)

cat <<EOF

✅ Deployment complete.

   Public IP : $IP
   SSH       : $SSH_CMD

First-boot provisioning (Docker + Node 22 + NemoClaw) runs for ~10-20 minutes.
Tail it with:

   $SSH_CMD
   sudo tail -f /var/log/cloud-init-output.log

Then connect to the sandbox:

   nemoclaw $ASSISTANT connect
EOF
