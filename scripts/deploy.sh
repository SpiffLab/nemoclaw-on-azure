#!/usr/bin/env bash
# Deploy NemoClaw on Azure.
# Requires: az CLI logged in, Bicep installed, an SSH public key.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --resource-group <name> --location <region> --ssh-public-key "<key>" [options]

Required:
  --resource-group NAME     Resource group (created if missing)
  --location REGION         e.g. eastus2
  --ssh-public-key STRING   Contents of your SSH public key

Options:
  --name-prefix NAME        Default: nemoclaw
  --vm-size SIZE            Default: Standard_D4s_v5
  --admin-username NAME     Default: azureuser
  --allowed-ssh-cidr CIDR   Default: 0.0.0.0/0 (narrow this for production)
  --assistant-name NAME     Default: my-assistant
  --os-disk-size-gb N       Default: 64

Environment:
  NVIDIA_API_KEY            Passed to the VM for routed inference (optional)
EOF
}

RG="" LOCATION="" SSH_KEY=""
PREFIX="nemoclaw" VM_SIZE="Standard_D4s_v5" ADMIN="azureuser"
SSH_CIDR="0.0.0.0/0" ASSISTANT="my-assistant" OS_DISK=64

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)    RG="$2"; shift 2 ;;
    --location)          LOCATION="$2"; shift 2 ;;
    --ssh-public-key)    SSH_KEY="$2"; shift 2 ;;
    --name-prefix)       PREFIX="$2"; shift 2 ;;
    --vm-size)           VM_SIZE="$2"; shift 2 ;;
    --admin-username)    ADMIN="$2"; shift 2 ;;
    --allowed-ssh-cidr)  SSH_CIDR="$2"; shift 2 ;;
    --assistant-name)    ASSISTANT="$2"; shift 2 ;;
    --os-disk-size-gb)   OS_DISK="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$RG" || -z "$LOCATION" || -z "$SSH_KEY" ]]; then
  usage; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$ROOT_DIR/infra/main.bicep"

echo "==> Ensuring resource group $RG ($LOCATION)"
az group create --name "$RG" --location "$LOCATION" --output none

DEPLOYMENT_NAME="nemoclaw-$(date +%Y%m%d%H%M%S)"
echo "==> Deploying $DEPLOYMENT_NAME"

az deployment group create \
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
      nvidiaApiKey="${NVIDIA_API_KEY:-}" \
      assistantName="$ASSISTANT" \
      osDiskSizeGB="$OS_DISK" \
  --output json > /tmp/nemoclaw-deploy.json

IP=$(jq -r '.properties.outputs.publicIpAddress.value' /tmp/nemoclaw-deploy.json)
SSH_CMD=$(jq -r '.properties.outputs.sshCommand.value' /tmp/nemoclaw-deploy.json)

cat <<EOF

✅ Deployment complete.

   Public IP : $IP
   SSH       : $SSH_CMD

First-boot provisioning runs for ~10–20 minutes. Tail it with:

   $SSH_CMD
   sudo tail -f /var/log/cloud-init-output.log

Then connect to the sandbox:

   nemoclaw $ASSISTANT connect
EOF
