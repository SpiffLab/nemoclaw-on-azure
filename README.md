# NemoClaw on Azure

Deploy the latest [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) reference
stack on an Azure VM using Bicep + cloud-init. NemoClaw installs the
[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) runtime and runs
[OpenClaw](https://openclaw.ai) always-on assistants inside a hardened sandbox
(Landlock + seccomp + netns).

> **Upstream status:** NemoClaw is in **alpha** (early preview since March 16,
> 2026). Interfaces may change. See
> [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) for current state.

> Replaces the archived
> [SpiffLab/nemoclaw-azure](https://github.com/SpiffLab/nemoclaw-azure).

---

## Architecture

```
┌────────────────────────── Azure Resource Group ──────────────────────────┐
│                                                                          │
│   VNet ── Subnet ── NSG (22/tcp from your IP only)                       │
│             │                                                            │
│             └── NIC ── Public IP                                         │
│                   │                                                      │
│                   └── Ubuntu 24.04 LTS VM (Standard_D4s_v5, 64 GB disk)  │
│                         └── cloud-init:                                  │
│                               • Docker Engine + compose plugin           │
│                               • nvm → Node 22                            │
│                               • curl … nemoclaw.sh | bash                │
│                               • nemoclaw onboard (unattended)            │
│                                                                          │
│   Inference: NVIDIA Endpoints (routed, default)                          │
│              or swap to bring-your-own provider post-onboard             │
└──────────────────────────────────────────────────────────────────────────┘
```

Default VM size **Standard_D4s_v5** (4 vCPU / 16 GB RAM) matches NemoClaw's
recommended profile for routed inference. For local model inference, pick a
GPU SKU via the `vmSize` parameter (e.g. `Standard_NC8as_T4_v3`,
`Standard_NC24ads_A100_v4`).

## Prerequisites

- Azure subscription with VM quota for your chosen SKU
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60+
- [Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (bundled with Azure CLI)
- An SSH public key (`~/.ssh/id_ed25519.pub` or similar)
- An [NVIDIA API key](https://build.nvidia.com/) for the default inference path
  (`NVIDIA_API_KEY`)

## Quick start

```bash
# Clone
git clone https://github.com/SpiffLab/nemoclaw-on-azure.git
cd nemoclaw-on-azure

# Log in + pick subscription
az login
az account set --subscription <SUBSCRIPTION_ID>

# Deploy (Linux/macOS)
export NVIDIA_API_KEY=nvapi-...
./scripts/deploy.sh \
  --resource-group rg-nemoclaw \
  --location eastus2 \
  --admin-username azureuser \
  --ssh-public-key "$(cat ~/.ssh/id_ed25519.pub)"
```

Windows PowerShell:

```powershell
$env:NVIDIA_API_KEY = "nvapi-..."
./scripts/deploy.ps1 `
  -ResourceGroup rg-nemoclaw `
  -Location eastus2 `
  -AdminUsername azureuser `
  -SshPublicKey (Get-Content $HOME/.ssh/id_ed25519.pub)
```

The deploy script:

1. Creates the resource group (if missing).
2. Deploys `infra/main.bicep`.
3. Prints the public IP and SSH command.

Cloud-init then installs Docker, Node 22 (via nvm), and runs the NemoClaw
installer. First-boot provisioning takes roughly 10–20 minutes. Follow it
with:

```bash
ssh azureuser@<public-ip>
sudo tail -f /var/log/cloud-init-output.log
```

## Using NemoClaw

Once onboarding completes:

```bash
# Connect to the sandbox
nemoclaw my-assistant connect

# In the sandbox shell
openclaw tui
# or one-shot
openclaw agent --agent main --local -m "hello" --session-id test
```

Status / logs:

```bash
nemoclaw my-assistant status
nemoclaw my-assistant logs --follow
```

## Teardown

```bash
az group delete --name rg-nemoclaw --yes --no-wait
```

Or uninstall NemoClaw in place (keeps the VM):

```bash
curl -fsSL https://raw.githubusercontent.com/NVIDIA/NemoClaw/refs/heads/main/uninstall.sh | bash
```

## Repository layout

```
nemoclaw-on-azure/
├── infra/
│   ├── main.bicep              # RG-scoped deployment: network + VM
│   ├── main.parameters.json    # Default parameters
│   └── modules/
│       ├── network.bicep       # VNet / subnet / NSG / public IP / NIC
│       └── vm.bicep            # Linux VM + cloud-init
├── scripts/
│   ├── cloud-init.yaml         # First-boot provisioning
│   ├── deploy.sh               # Bash deploy wrapper
│   └── deploy.ps1              # PowerShell deploy wrapper
├── docs/
│   └── architecture.md
├── azure.yaml                  # azd compatibility
├── LICENSE
└── README.md
```

## License

[Apache 2.0](./LICENSE). NemoClaw and OpenShell are NVIDIA projects under their
own licenses.
