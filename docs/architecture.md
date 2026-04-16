# Architecture

## Goals

- Provide a **minimal, reproducible** Azure deployment for the upstream
  [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) reference stack.
- Match the NemoClaw project's own install path as closely as possible
  (`curl … nemoclaw.sh | bash` on a supported Linux host with Docker) so this
  repo stays easy to keep in sync with alpha-stage upstream changes.
- Keep the surface area small: one VM, one NSG, one public IP.

## Components

| Resource              | Purpose                                                               |
| --------------------- | --------------------------------------------------------------------- |
| `vnet` + `subnet`     | Private network (10.42.0.0/16, `default` subnet 10.42.1.0/24).        |
| `nsg`                 | Inbound: TCP/22 from `allowedSshCidr`. All egress allowed.            |
| `publicIp` (Standard) | Static IP with DNS label `<prefix>-<hash>.<region>.cloudapp.azure.com`. |
| `nic`                 | Attaches the VM to the subnet + public IP.                            |
| `vm` (Ubuntu 24.04)   | Runs Docker, nvm/Node 22, and the NemoClaw installer via cloud-init.  |

## First-boot flow

1. **Docker** — installed via `get.docker.com`, enabled, admin user added to
   `docker` group.
2. **Node 22** — installed via [nvm](https://github.com/nvm-sh/nvm) into the
   admin user's home (matches NemoClaw's recommended setup: Node ≥22.16, npm ≥10).
3. **NemoClaw installer** — `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`
   runs as the admin user. The installer handles `nemoclaw onboard`, creating
   the OpenShell gateway and the sandbox.
4. **Inference** — if `NVIDIA_API_KEY` is supplied at deploy time it is
   exported before the installer runs and persisted in `~/.bashrc`. Leave it
   empty to configure inference interactively on first connect.

All steps log to `/var/log/nemoclaw-bootstrap.log` in addition to the standard
`/var/log/cloud-init-output.log`.

## Sizing guidance

NemoClaw's published minimums: 4 vCPU / 8 GB RAM / 20 GB disk. The sandbox
image is ~2.4 GB compressed and the installer buffers decompressed layers,
which can trigger the OOM killer on 8 GB machines. We default to:

- **`Standard_D4s_v5`** (4 vCPU / 16 GB) — recommended profile for routed
  inference against NVIDIA Endpoints (default model:
  `nvidia/nemotron-3-super-120b-a12b`).
- **64 GB Premium SSD** — leaves headroom for model pulls if you later switch
  to a local provider.

For local GPU inference, pick an NC-series SKU via `vmSize`. The VM image and
cloud-init logic are unchanged; you will need to install the NVIDIA driver and
the NVIDIA Container Toolkit separately (not yet scripted here).

## Security notes

- **SSH exposure.** The default NSG rule allows SSH from `0.0.0.0/0` for
  convenience. In anything other than throwaway testing, set
  `--allowed-ssh-cidr <your-ip>/32` (or front the VM with Azure Bastion and
  remove the rule entirely).
- **Secrets.** `sshPublicKey` and `nvidiaApiKey` are declared `@secure()`;
  values do not appear in deployment outputs. `nvidiaApiKey` is rendered into
  the VM's `customData` (cloud-init) and persisted to the admin user's
  `~/.bashrc`. Treat the VM as holding that secret.
- **Sandbox hardening.** The NemoClaw sandbox itself adds Landlock + seccomp +
  network namespaces around OpenClaw. See
  [Sandbox Hardening](https://docs.nvidia.com/nemoclaw/latest/deployment/sandbox-hardening.html)
  upstream for the full control set.

## What this repo does **not** do (yet)

- GPU driver + NVIDIA Container Toolkit install (needed for local inference
  on NC/ND SKUs).
- Bastion / Private Link / managed identity wiring.
- Multi-assistant orchestration — only a single `assistantName` is onboarded.
- CI pipeline to `az deployment group what-if` on PRs.

Contributions welcome.
