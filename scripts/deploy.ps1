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

function Get-MyPublicIp {
  try { (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip }
  catch { $null }
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

if (-not $AllowedSshCidr) {
  $ip = Get-MyPublicIp
  if ($ip) {
    $suggested = "$ip/32"
    Write-Host ""
    Write-Host "Detected your public IP: $ip" -ForegroundColor Cyan
    $ans = Read-Host "  Restrict SSH to $suggested ? [Y/n]"
    if ($ans -match '^[Nn]') { $AllowedSshCidr = '0.0.0.0/0' } else { $AllowedSshCidr = $suggested }
  } else {
    $AllowedSshCidr = Read-Host "CIDR allowed to reach SSH (default: 0.0.0.0/0)"
    if (-not $AllowedSshCidr) { $AllowedSshCidr = '0.0.0.0/0' }
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
