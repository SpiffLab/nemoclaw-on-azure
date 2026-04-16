<#
.SYNOPSIS
  Deploy NemoClaw on Azure (interactive-friendly).

.DESCRIPTION
  Prompts for any required inputs that weren't supplied on the command line,
  validates the target Azure subscription, then deploys infra/main.bicep.

.EXAMPLE
  # Fully interactive — prompts for everything
  ./scripts/deploy.ps1

.EXAMPLE
  # Fully scripted
  $env:NVIDIA_API_KEY = 'nvapi-...'
  ./scripts/deploy.ps1 -SubscriptionId bf76... -ResourceGroup rg-nemoclaw-01 `
      -Location centralus -SshPublicKey (Get-Content $HOME/.ssh/id_rsa.pub -Raw).Trim()
#>
[CmdletBinding()]
param(
  [string] $SubscriptionId,
  [string] $ResourceGroup,
  [string] $Location        = 'centralus',
  [string] $SshPublicKey,
  [string] $NvidiaApiKey,
  [string] $AllowedSshCidr,
  [string] $NamePrefix      = 'nemoclaw',
  [string] $VmSize          = 'Standard_D4s_v4',
  [string] $AdminUsername   = 'azureuser',
  [string] $AssistantName   = 'my-assistant',
  [int]    $OsDiskSizeGB    = 64
)

$ErrorActionPreference = 'Stop'

function Read-NonEmpty([string]$prompt) {
  while ($true) {
    $v = Read-Host -Prompt $prompt
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    Write-Host "  value is required." -ForegroundColor Yellow
  }
}

function Confirm-SshCidr([string]$cidr) {
  # Accept a.b.c.d or a.b.c.d/nn; reject anything that looks like "open to everyone"
  # unless the user re-types it with eyes open.
  $cidr = $cidr.Trim()
  if ($cidr -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return "$cidr/32" }
  if ($cidr -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') { return $cidr }
  if ($cidr -in @('*','0.0.0.0/0','Internet')) {
    Write-Host ""
    Write-Host "⚠  You asked to allow SSH from the entire internet." -ForegroundColor Red
    $confirm = Read-Host "   Type 'I ACCEPT' to confirm, anything else to re-enter"
    if ($confirm -eq 'I ACCEPT') { return '0.0.0.0/0' }
    return $null
  }
  Write-Host "  '$cidr' doesn't look like a valid IP or CIDR." -ForegroundColor Yellow
  return $null
}

# ---------- Prompt for missing required inputs ----------

if (-not $SubscriptionId) {
  Write-Host ""
  Write-Host "Azure subscription:" -ForegroundColor Cyan
  az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o table
  $SubscriptionId = Read-NonEmpty "  Subscription ID"
}

if (-not $ResourceGroup) {
  $ResourceGroup = Read-NonEmpty "Resource group name (will be created if missing)"
}

if (-not $AllowedSshCidr) {
  Write-Host ""
  Write-Host "SSH source IP / CIDR (who is allowed to SSH to the VM):" -ForegroundColor Cyan
  Write-Host "  - Enter your workstation's public IP (e.g. 70.139.21.206) — /32 will be added." -ForegroundColor Gray
  Write-Host "  - Or a CIDR range (e.g. 70.139.21.0/24)." -ForegroundColor Gray
  Write-Host "  - To find your IP: open https://ifconfig.me or run 'curl ifconfig.me'." -ForegroundColor Gray
  while (-not $AllowedSshCidr) {
    $raw = Read-NonEmpty "  Allowed SSH source"
    $AllowedSshCidr = Confirm-SshCidr $raw
  }
}

if (-not $SshPublicKey) {
  $candidates = @("$HOME/.ssh/id_ed25519.pub", "$HOME/.ssh/id_rsa.pub") |
    Where-Object { Test-Path $_ }
  if ($candidates.Count -gt 0) {
    $SshPublicKey = (Get-Content $candidates[0] -Raw).Trim()
    Write-Host "Using SSH public key from $($candidates[0])" -ForegroundColor Gray
  } else {
    Write-Host "No SSH key found at ~/.ssh/id_ed25519.pub or id_rsa.pub."
    Write-Host "Generate one with:  ssh-keygen -t ed25519 -C 'nemoclaw'"
    $SshPublicKey = Read-NonEmpty "Paste your SSH public key contents"
  }
}

if (-not $NvidiaApiKey) {
  if ($env:NVIDIA_API_KEY) {
    $NvidiaApiKey = $env:NVIDIA_API_KEY
    Write-Host "Using NVIDIA_API_KEY from environment." -ForegroundColor Gray
  } else {
    Write-Host ""
    Write-Host "NVIDIA API key (from https://build.nvidia.com/) — used for routed inference." -ForegroundColor Cyan
    Write-Host "Leave blank to skip; you will need to run 'nemoclaw onboard' manually on the VM." -ForegroundColor Gray
    $NvidiaApiKey = Read-Host -Prompt "  NVIDIA API key (optional)"
    if ($null -eq $NvidiaApiKey) { $NvidiaApiKey = '' }
  }
}

# ---------- Select subscription ----------

Write-Host ""
Write-Host "==> Selecting subscription $SubscriptionId"
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription $SubscriptionId." }

$acct = az account show -o json | ConvertFrom-Json
Write-Host "   Using: $($acct.name) ($($acct.id))" -ForegroundColor Gray

# ---------- Deploy ----------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$template  = Join-Path $scriptDir '..\infra\main.bicep'

Write-Host "==> Ensuring resource group $ResourceGroup ($Location)"
az group create --name $ResourceGroup --location $Location --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to create/validate resource group $ResourceGroup." }

$deploymentName = "nemoclaw-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "==> Deploying $deploymentName (this takes ~2-4 minutes for infra)"

$resultJson = az deployment group create `
  --resource-group $ResourceGroup `
  --name $deploymentName `
  --template-file $template `
  --parameters `
      namePrefix=$NamePrefix `
      location=$Location `
      vmSize=$VmSize `
      adminUsername=$AdminUsername `
      sshPublicKey="$SshPublicKey" `
      allowedSshCidr=$AllowedSshCidr `
      nvidiaApiKey="$NvidiaApiKey" `
      assistantName=$AssistantName `
      osDiskSizeGB=$OsDiskSizeGB `
  --output json

if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "❌ Deployment FAILED." -ForegroundColor Red
  Write-Host "   Inspect errors with:" -ForegroundColor Yellow
  Write-Host "     az deployment group show -g $ResourceGroup -n $deploymentName --query properties.error"
  Write-Host "     az deployment operation group list -g $ResourceGroup -n $deploymentName --query `"[?properties.provisioningState=='Failed']`""
  throw "Deployment $deploymentName failed."
}

$result = $resultJson | ConvertFrom-Json
$ip     = $result.properties.outputs.publicIpAddress.value
$sshCmd = $result.properties.outputs.sshCommand.value

Write-Host ""
Write-Host "✅ Deployment complete." -ForegroundColor Green
Write-Host "   Public IP : $ip"
Write-Host "   SSH       : $sshCmd"
Write-Host ""
Write-Host "First-boot provisioning (Docker + Node 22 + NemoClaw) runs for ~10-20 minutes."
Write-Host "Tail it with:"
Write-Host "   $sshCmd"
Write-Host "   sudo tail -f /var/log/cloud-init-output.log"
Write-Host ""
Write-Host "Then connect to the sandbox:"
Write-Host "   nemoclaw $AssistantName connect"
