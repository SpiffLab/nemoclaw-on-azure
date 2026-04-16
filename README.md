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

## 🔒 Secrets & safety

**This repository contains no secrets.** `infra/main.parameters.json` is a
template with placeholder values only — `REPLACE_WITH_SSH_PUBLIC_KEY`,
`REPLACE_WITH_YOUR_IP/32`, and an empty `nvidiaApiKey`. **Do not commit
real values into it.** To store your own values, either:

- Pass them as CLI arguments / environment variables to
  `scripts/deploy.sh` / `scripts/deploy.ps1` (the scripts never persist
  them), or
- Create a `infra/main.parameters.local.json` — the name is already in
  `.gitignore` and will not be tracked.

Things you should treat as credentials once the VM is up:

- **NVIDIA API key** — cloud-init writes it to `~azureuser/.bashrc` on the
  VM. Anyone with shell on the VM can read it. Rotate via
  [build.nvidia.com](https://build.nvidia.com/) if exposed.
- **OpenClaw dashboard token** — printed by `nemoclaw my-assistant
  status`. Anyone who has it **and** access to your tunnel's local
  `127.0.0.1:18789` can drive the sandbox. It is not stored anywhere in
  this repo.
- **SSH private key** — your usual workstation-side key; `*.pub`/`*.pem`
  are excluded by `.gitignore` to prevent accidental commits.

The NSG opens **only** port 22 inbound, and only from the CIDR /
service-tag you provide at deploy time. There is **no wildcard default**
and no port is opened for the dashboard — it rides entirely inside the
SSH tunnel (see [OpenClaw web dashboard](#openclaw-web-dashboard-ssh-tunnel)
below).

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
| **SSH source** | Restricts who can reach port 22 on the VM. **Required** — there is no wildcard default. Accepts a workstation IP (`203.0.113.42` → auto-normalized to `/32`), a CIDR range, **or an Azure NSG service tag** (e.g. `AzureCloud`) — use a service tag if your corporate VPN routes through Azure and your egress IP rotates across many Azure NATs. `0.0.0.0/0` / `*` requires an explicit `I ACCEPT` confirmation. | `curl ifconfig.me` or open [ifconfig.me](https://ifconfig.me) in a browser. If your VPN/IP rotates across Azure IPs, use `AzureCloud`. |
| **NVIDIA API key** *(optional but strongly recommended)* | Used by `nemoclaw onboard` for routed inference against NVIDIA Endpoints. **Without it, cloud-init onboarding will fail** and you'll need to SSH in and run the installer interactively. | [build.nvidia.com](https://build.nvidia.com/) → API key. Set via `NVIDIA_API_KEY` env var or the script will prompt. |

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

### OpenClaw web dashboard (SSH tunnel)

The dashboard is bound to `127.0.0.1:18789` **inside the sandbox's network
namespace** — it's not on a public port and there is no NSG rule for it.
You reach it through an SSH tunnel over the already-open port 22.

Cloud-init installs a systemd unit (`openclaw-dashboard-forward.service`)
that runs `openshell forward start 18789 <assistant-name>` at boot, which
proxies the sandbox's loopback dashboard to `127.0.0.1:18789` on the VM
**host**. Your SSH tunnel then connects your workstation's `127.0.0.1:18789`
to the VM's `127.0.0.1:18789`, so the dashboard never leaves either
machine's loopback interface — no public exposure, no extra firewall rule.

```
  your browser          SSH -L tunnel              VM host                 sandbox
 ┌───────────┐   ┌─────────────────────────┐   ┌───────────────┐   ┌───────────────────┐
 │127.0.0.1  │──▶│ encrypted over port 22  │──▶│127.0.0.1:18789│──▶│127.0.0.1:18789    │
 │    :18789 │   │                         │   │ (openshell    │   │ (openclaw UI)     │
 └───────────┘   └─────────────────────────┘   │  forward)     │   └───────────────────┘
                                               └───────────────┘
```

**Step-by-step:**

1. **Open the tunnel** (keep this terminal open for the whole session):

   ```bash
   # macOS / Linux / WSL / Git Bash
   ssh -N -L 18789:127.0.0.1:18789 azureuser@<public-ip>

   # PowerShell on Windows (same command; -N means "don't run a remote shell")
   ssh -N -L 18789:127.0.0.1:18789 azureuser@<public-ip>
   ```

   `-N` keeps the tunnel open without opening an interactive shell, so you
   won't see `channel N: open failed: connect failed` spam if your browser
   makes requests before the forward is up. Drop the `-N` if you want an
   interactive shell on the VM at the same time.

2. **Fetch the dashboard URL + token** from another terminal:

   ```bash
   ssh azureuser@<public-ip> 'nemoclaw my-assistant status'
   ```

   Look for a line like:
   ```
   Dashboard: http://127.0.0.1:18789/#token=<long-random-string>
   ```
   **Treat the token as a password** — anyone who has it and access to your
   workstation's `127.0.0.1:18789` can drive the sandbox. It's not stored
   in this repo.

3. **Open that URL in your browser** (on your workstation — it's your
   local loopback hitting the tunnel).

**If you see `channel N: open failed: connect failed: Connection refused`**
on the client side, the host-side forward isn't running. Fix:

```bash
ssh azureuser@<public-ip> \
  'sudo systemctl restart openclaw-dashboard-forward && \
   openshell forward list'
```

You should see `my-assistant  127.0.0.1  18789  <pid>  running`. If the
sandbox was restarted, the forward may take up to 5 minutes to reappear
while the unit's `ExecStartPre` waits for the sandbox to become `Ready`.

**Tunnel-less alternative:** you can also just run `openclaw tui` inside
the sandbox — no browser, no forwarding, fully text-mode:

```bash
ssh azureuser@<public-ip>
nemoclaw my-assistant connect
openclaw tui
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
- **SSH CIDR is required — no wildcard default.** Earlier versions
  auto-detected the source IP via `api.ipify.org`, which reports the
  *upstream proxy* IP in CGNAT or Copilot-CLI environments (different from
  what Azure's NSG actually sees). The script now requires you to enter an
  IP/CIDR/service-tag explicitly, and treats `0.0.0.0/0` as a dangerous
  choice that must be confirmed with `I ACCEPT`. Find your actual public
  IP with `curl ifconfig.me` *on the same workstation you will SSH from*.

- **Corporate VPN that routes through Azure.** Some VPN clients
  (GlobalProtect-on-Azure, ExpressRoute user tunnels, etc.) NAT your
  outbound traffic through rotating Azure public IPs, so a `/32` allow-list
  will break every few minutes. Use the **`AzureCloud` service tag** as
  your SSH source in that case — it covers every Azure public IP range and
  your SSH key remains the real access control. Symptom: `sshd` logs show
  you arriving from several different `20.x.x.x` / `52.x.x.x` addresses
  within the same session.
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
