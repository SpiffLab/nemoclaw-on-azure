<#
.SYNOPSIS
  Deploy NemoClaw on Azure.

.EXAMPLE
  $env:NVIDIA_API_KEY = 'nvapi-...'
  ./scripts/deploy.ps1 -ResourceGroup rg-nemoclaw -Location eastus2 `
      -SshPublicKey (Get-Content $HOME/.ssh/id_ed25519.pub)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $Location,
  [Parameter(Mandatory)] [string] $SshPublicKey,
  [string] $NamePrefix      = 'nemoclaw',
  [string] $VmSize          = 'Standard_D4s_v5',
  [string] $AdminUsername   = 'azureuser',
  [string] $AllowedSshCidr  = '0.0.0.0/0',
  [string] $AssistantName   = 'my-assistant',
  [int]    $OsDiskSizeGB    = 64
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$template  = Join-Path $scriptDir '..\infra\main.bicep'

Write-Host "==> Ensuring resource group $ResourceGroup ($Location)"
az group create --name $ResourceGroup --location $Location --output none

$deploymentName = "nemoclaw-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "==> Deploying $deploymentName"

$nvidiaKey = $env:NVIDIA_API_KEY
if (-not $nvidiaKey) { $nvidiaKey = '' }

$result = az deployment group create `
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
      nvidiaApiKey="$nvidiaKey" `
      assistantName=$AssistantName `
      osDiskSizeGB=$OsDiskSizeGB `
  --output json | ConvertFrom-Json

$ip     = $result.properties.outputs.publicIpAddress.value
$sshCmd = $result.properties.outputs.sshCommand.value

Write-Host ""
Write-Host "✅ Deployment complete." -ForegroundColor Green
Write-Host "   Public IP : $ip"
Write-Host "   SSH       : $sshCmd"
Write-Host ""
Write-Host "First-boot provisioning runs for ~10-20 minutes. Tail it with:"
Write-Host "   $sshCmd"
Write-Host "   sudo tail -f /var/log/cloud-init-output.log"
Write-Host ""
Write-Host "Then connect to the sandbox:"
Write-Host "   nemoclaw $AssistantName connect"
