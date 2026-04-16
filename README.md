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

You will be **prompted for these at deploy time** if not supplied — but to run
fully non-interactively, have them ready:

| Input | Why | How to get it |
| --- | --- | --- |
| **Azure subscription ID** | The sub that will be billed. The Azure default `MSFT-Provisioning-01` sub does **not** allow direct RG creation — you need a sub where you have `Contributor` or `Owner`. | `az account list -o table` |
| **Resource group name** | Created if missing. | You choose (e.g. `rg-nemoclaw-01`). |
| **SSH public key** | Authenticates you to the VM. | `~/.ssh/id_ed25519.pub` (or `ssh-keygen -t ed25519 -C nemoclaw`). |
| **NVIDIA API key** *(optional but strongly recommended)* | Used by `nemoclaw onboard` for routed inference against NVIDIA Endpoints. **Without it, cloud-init onboarding will fail** and you'll need to SSH in and run the installer interactively. | [build.nvidia.com](https://build.nvidia.com/) → API key. Set via `NVIDIA_API_KEY` env var or the script will prompt. |
| **Your public IP** *(optional)* | Narrows the SSH NSG rule to `<ip>/32`. The script auto-detects via `api.ipify.org` and asks to confirm; fallback is `0.0.0.0/0`. | — |

Also required on your workstation:

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60+
- [Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (bundled with Azure CLI)
- `az login` against a tenant where your target subscription lives

### A note on region + SKU

The default is **`centralus` / `Standard_D4s_v4`** because that combination had
free capacity in the MCAPS subscription this repo was first validated against.
`Standard_D4s_v5` / `D4as_v5` in `eastus` and `eastus2` are frequently
capacity-restricted on new subs. Override with `-Location` / `-VmSize`
(PowerShell) or `--location` / `--vm-size` (bash) as needed.

## Quick start

Both deploy scripts are **interactive-friendly** — run with no args to be
prompted for subscription, resource group, SSH key, NVIDIA key, and SSH
source IP.

```bash
# Clone
git clone https://github.com/SpiffLab/nemoclaw-on-azure.git
cd nemoclaw-on-azure

az login                                 # sign in; tenant must host your target sub
./scripts/deploy.sh                      # fully interactive — prompts for everything
```

Fully scripted (Linux/macOS):

```bash
export NVIDIA_API_KEY=nvapi-...
./scripts/deploy.sh \
  --subscription-id <SUB_ID> \
  --resource-group rg-nemoclaw-01 \
  --location centralus \
  --ssh-public-key "$(cat ~/.ssh/id_ed25519.pub)"
```

Windows PowerShell:

```powershell
./scripts/deploy.ps1                     # fully interactive

# or scripted:
$env:NVIDIA_API_KEY = "nvapi-..."
./scripts/deploy.ps1 `
  -SubscriptionId <SUB_ID> `
  -ResourceGroup rg-nemoclaw-01 `
  -Location centralus `
  -SshPublicKey (Get-Content $HOME/.ssh/id_rsa.pub -Raw).Trim()
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

## Troubleshooting & lessons learned

This repo was iterated on a real Azure deployment. First-try pitfalls worth
knowing about:

- **Region/SKU capacity.** `Standard_D4s_v5` and `Standard_D4as_v5` are often
  capacity-restricted on new MCAPS subscriptions in `eastus`/`eastus2`.
  Defaults are now `centralus` + `Standard_D4s_v4`. Check with:
  ```bash
  az vm list-skus -l <region> --size Standard_D4 --query "[?restrictions[0]]" -o table
  ```
- **SSH CIDR auto-detection can be wrong behind corporate/CGNAT NAT.**
  Public IP reported by `api.ipify.org` doesn't always match the IP Azure
  actually sees. If SSH fails with `kex_exchange_identification: Connection
  closed by remote host` right after deploy, widen the rule and check the
  real source IP:
  ```bash
  az network nsg rule update -g <rg> --nsg-name nemoclaw-nsg \
      -n AllowSshInbound --source-address-prefixes '*'
  ssh azureuser@<ip> 'echo $SSH_CLIENT'   # first column is your real source IP
  az network nsg rule update -g <rg> --nsg-name nemoclaw-nsg \
      -n AllowSshInbound --source-address-prefixes '<real-ip>/32'
  ```
- **Ubuntu 24.04 `/run/sshd` race.** On some first boots the openssh-server
  tmpfiles.d rule loses to cloud-init, leaving sshd unable to start
  (`Missing privilege separation directory: /run/sshd`). Socket-activated
  SSH silently closes connections in that state. `scripts/cloud-init.yaml`
  now creates the directory and restarts the SSH socket early in `runcmd`.
- **NemoClaw installer needs `NEMOCLAW_NON_INTERACTIVE=1
  --yes-i-accept-third-party-software` under cloud-init.** The installer
  prompts for third-party software acceptance on `/dev/tty`; without a TTY
  it aborts. The bootstrap script downloads the installer then invokes it
  with both flags set.
- **`az deployment group create` failures are silent-ish.** Earlier
  versions of the deploy wrappers continued past failures and printed
  "✅ Deployment complete" even when deployment had failed. The current
  scripts check `$LASTEXITCODE`/exit status and fail loudly, pointing you
  at `az deployment operation group list`.

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
│   ├── deploy.sh               # Bash deploy wrapper (prompts for missing inputs)
│   └── deploy.ps1              # PowerShell deploy wrapper (prompts for missing inputs)
├── docs/
│   └── architecture.md
├── azure.yaml                  # azd compatibility
├── LICENSE
└── README.md
```

## License

[Apache 2.0](./LICENSE). NemoClaw and OpenShell are NVIDIA projects under their
own licenses.
