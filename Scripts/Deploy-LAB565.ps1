<# 
Deploy-LAB565.ps1
- Interactive az login
- Find target RG (or use provided)
- Ensure ACR exists (in same RG)
- Download Dockerfile/.dockerignore into C:\labs\hr-mcp-server
- ACR cloud build (no Docker required)
- Deploy Bicep
- Print MCP URL + header + API key
#>

[CmdletBinding()]
param(
  # Change only if you rename the repo/branch
  [string]$RepoOwner = "okalb",
  [string]$RepoName  = "40-505-50",
  [string]$Branch    = "main",

  # If blank, script will auto-find an RG containing 'LAB565'
  [string]$ResourceGroupName = "",

  # Local path on the lab VM where the MCP server source code lives
  [string]$McpSourcePath = "C:\labs\hr-mcp-server",

  # Image tag
  [string]$ImageTag = "v1"
)

$ErrorActionPreference = "Stop"

function Fail($msg) { throw $msg }

function Require-AzCli {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Fail "Azure CLI (az) is not installed or not on PATH."
  }
}

function Ensure-LoggedIn {
  try {
    az account show --only-show-errors | Out-Null
  } catch {
    Write-Host "Signing into Azure (interactive)..." -ForegroundColor Yellow
    az login --only-show-errors | Out-Null
  }
}

function Resolve-ResourceGroup {
  param([string]$Rg)

  if ($Rg) { return $Rg }

  # Prefer RGs that include LAB565
  $candidates = az group list --query "[?contains(name,'LAB565')].[name]" -o tsv --only-show-errors
  if (-not $candidates) {
    Fail "Couldn't auto-find a resource group containing 'LAB565'. Re-run with -ResourceGroupName <name>."
  }

  # If multiple, pick the first
  return ($candidates | Select-Object -First 1).Trim()
}

function Ensure-ProviderRegistered($ns) {
  $state = az provider show --namespace $ns --query registrationState -o tsv 2>$null
  if ($state -ne "Registered") {
    az provider register --namespace $ns --only-show-errors | Out-Null
  }

  for ($i=0; $i -lt 60; $i++) {
    $state = az provider show --namespace $ns --query registrationState -o tsv 2>$null
    if ($state -eq "Registered") { return }
    Start-Sleep -Seconds 5
  }
  Fail "Provider $ns did not reach Registered state in time."
}

Require-AzCli
Ensure-LoggedIn

$rg = Resolve-ResourceGroup $ResourceGroupName
Write-Host "Using Resource Group: $rg" -ForegroundColor Cyan

$rgLocation = (az group show -n $rg --query location -o tsv --only-show-errors).Trim()
Write-Host "RG Location: $rgLocation" -ForegroundColor Cyan

# Providers needed by your template + container apps
Ensure-ProviderRegistered "Microsoft.App"
Ensure-ProviderRegistered "Microsoft.ContainerRegistry"
Ensure-ProviderRegistered "Microsoft.Storage"
Ensure-ProviderRegistered "Microsoft.Search"
Ensure-ProviderRegistered "Microsoft.CognitiveServices"
Ensure-ProviderRegistered "Microsoft.Authorization"

# -------------------------
# ACR in same RG
# -------------------------
$subId = (az account show --query id -o tsv --only-show-errors).Trim()

# Avoid collisions: hash includes subscription + rg
$bytes  = [System.Text.Encoding]::UTF8.GetBytes("$subId|$rg")
$sha    = [System.Security.Cryptography.SHA256]::Create()
$hash   = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
$acrName = ("acrhrmcp" + $hash.Substring(0,18)).ToLower()

Write-Host "ACR Name: $acrName" -ForegroundColor Cyan

$acrExists = az acr show -g $rg -n $acrName --query name -o tsv 2>$null
if (-not $acrExists) {
  Write-Host "Creating ACR..." -ForegroundColor Yellow
  az acr create -g $rg -n $acrName -l $rgLocation --sku Basic --admin-enabled true --only-show-errors | Out-Null
} else {
  az acr update -g $rg -n $acrName --admin-enabled true --only-show-errors | Out-Null
}

# -------------------------
# Ensure Dockerfile present (download from GitHub)
# -------------------------
if (-not (Test-Path $McpSourcePath)) {
  Fail "MCP source path not found: $McpSourcePath"
}

$dockerfileUrl   = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/MCPContainer/Dockerfile"
$dockerignoreUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/MCPContainer/.dockerignore"

$dockerfilePath   = Join-Path $McpSourcePath "Dockerfile"
$dockerignorePath = Join-Path $McpSourcePath ".dockerignore"

Write-Host "Downloading Dockerfile + .dockerignore..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $dockerfileUrl -OutFile $dockerfilePath
Invoke-WebRequest -Uri $dockerignoreUrl -OutFile $dockerignorePath

if ((Get-Item $dockerfilePath).Length -lt 50) {
  Fail "Dockerfile download looks wrong/empty: $dockerfilePath"
}

# -------------------------
# Build image in ACR (no Docker needed)
# -------------------------
$repo = "hr-mcp-server"
$tagCount = az acr repository show-tags -n $acrName --repository $repo --query "[?@=='$ImageTag'] | length(@)" -o tsv 2>$null

if ($tagCount -ne "1") {
  Write-Host "Building container image in ACR (this can take a few minutes)..." -ForegroundColor Yellow
  Push-Location $McpSourcePath
  az acr build -r $acrName -t "$repo:$ImageTag" . --only-show-errors | Out-Null
  Pop-Location
} else {
  Write-Host "Image already exists: $repo:$ImageTag (skipping build)" -ForegroundColor Green
}

# -------------------------
# Deploy Bicep
# -------------------------
$bicepUrl  = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/AzureTemplates/LAB565.bicep"
$bicepPath = Join-Path $env:TEMP "LAB565.bicep"

Write-Host "Downloading Bicep..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $bicepUrl -OutFile $bicepPath

# Lab user object id: simplest approach is the signed-in user
$userObjectId = (az ad signed-in-user show --query id -o tsv 2>$null).Trim()
if (-not $userObjectId) {
  Fail "Couldn't determine signed-in user object id. Make sure your account can query Entra ID."
}

$mcpKey = [guid]::NewGuid().ToString("N")
$deploymentName = "deployment"

Write-Host "Deploying resources..." -ForegroundColor Yellow
az deployment group create `
  --name $deploymentName `
  --resource-group $rg `
  --template-file $bicepPath `
  --parameters labUserObjectId="$userObjectId" `
              location="$rgLocation" `
              acrResourceGroup="$rg" `
              acrName="$acrName" `
              mcpImageTag="$ImageTag" `
              mcpApiKey="$mcpKey" `
  --only-show-errors | Out-Null

# -------------------------
# Output student copy/paste values
# -------------------------
$mcpBaseUrl = (az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpBaseUrl.value" -o tsv).Trim()
$mcpHeader  = (az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpHeaderName.value" -o tsv).Trim()

""
"==== STUDENT COPY/PASTE ===="
"MCP Base URL : $mcpBaseUrl"
"Header Name : $mcpHeader"
"API Key     : $mcpKey"
"==========================="
""
