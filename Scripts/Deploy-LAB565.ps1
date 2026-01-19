<# 
Deploy-LAB565.ps1 (student-run)
- Interactive az login (only if not already logged in)
- Choose/find target RG
- Ensure ACR exists (in same RG) + admin enabled (needed for Bicep listCredentials pattern)
- Download Dockerfile/.dockerignore into C:\labs\hr-mcp-server
- ACR cloud build (no Docker required)
- Download + validate Bicep
- Deploy Bicep (MCP-only version)
- Print MCP URL + header + API key
- Write copy/paste values to Desktop file (MCP_Info.txt)
#>

[CmdletBinding()]
param(
  [string]$RepoOwner = "okalb",
  [string]$RepoName  = "40-505-50",
  [string]$Branch    = "main",

  # Optional: specify RG explicitly to avoid ambiguity
  [string]$ResourceGroupName = "",

  [string]$McpSourcePath = "C:\labs\hr-mcp-server",
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
  # Check if we can get a management (ARM) access token
  & az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv --only-show-errors 1>$null 2>$null

  if ($LASTEXITCODE -ne 0) {
    Write-Host "Signing into Azure (interactive)..." -ForegroundColor Yellow

    # Browser login (default)
    & az login --only-show-errors | Out-Null

    # If browser auth is flaky in your lab, use device code instead:
    # & az login --use-device-code --only-show-errors | Out-Null

    # Re-check token to confirm login succeeded
    & az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
      Fail "Azure CLI login did not complete successfully."
    }
  }
}


function Resolve-ResourceGroup {
  param([string]$Rg)

  if ($Rg) { return $Rg.Trim() }

  $q = "[?contains(name, 'LAB565')].name"
  $matches = & az group list --query $q -o tsv --only-show-errors
  if (-not $matches) {
    Fail "Couldn't auto-find a resource group containing 'LAB565'. Re-run with -ResourceGroupName <name>."
  }

  $list = @($matches | ForEach-Object { $_.Trim() } | Where-Object { $_ })

  if ($list.Count -eq 1) { return $list[0] }

  $preferred = $list | Where-Object { $_ -match 'ResourceGroup' } | Select-Object -First 1
  if ($preferred) { return $preferred }

  Write-Host ""
  Write-Host "Multiple resource groups match 'LAB565'. Choose one:" -ForegroundColor Yellow
  for ($i=0; $i -lt $list.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i+1), $list[$i])
  }
  $choice = Read-Host "Enter a number"
  if ($choice -notmatch '^\d+$') { Fail "Invalid choice." }
  $idx = [int]$choice - 1
  if ($idx -lt 0 -or $idx -ge $list.Count) { Fail "Choice out of range." }
  return $list[$idx]
}

function Ensure-ProviderRegistered($ns) {
  $state = & az provider show --namespace $ns --query registrationState -o tsv 2>$null
  if ($state -ne "Registered") {
    & az provider register --namespace $ns --only-show-errors | Out-Null
  }

  for ($i=0; $i -lt 60; $i++) {
    $state = & az provider show --namespace $ns --query registrationState -o tsv 2>$null
    if ($state -eq "Registered") { return }
    Start-Sleep -Seconds 5
  }
  Fail "Provider $ns did not reach Registered state in time."
}

function Get-DesktopPath {
  $desktop = [Environment]::GetFolderPath('Desktop')
  if (-not $desktop -or -not (Test-Path $desktop)) {
    $desktop = Join-Path $env:USERPROFILE "Desktop"
  }
  if (-not (Test-Path $desktop)) {
    Fail "Could not resolve a Desktop path for this user profile."
  }
  return $desktop
}

# -------------------------
# Start
# -------------------------
Require-AzCli
Ensure-LoggedIn

$rg = Resolve-ResourceGroup $ResourceGroupName
Write-Host "Using Resource Group: $rg" -ForegroundColor Cyan

$rgLocation = (& az group show -n $rg --query location -o tsv --only-show-errors).Trim()
Write-Host "RG Location: $rgLocation" -ForegroundColor Cyan

# Providers needed for MCP-only template + ACR
# NOTE: Provider registration often requires subscription-level permissions.
# If your lab subscription is already pre-registered, you can remove these calls.
Ensure-ProviderRegistered "Microsoft.App"
Ensure-ProviderRegistered "Microsoft.ContainerRegistry"

# -------------------------
# ACR in same RG
# -------------------------
$subId = (& az account show --query id -o tsv --only-show-errors).Trim()

$bytes  = [System.Text.Encoding]::UTF8.GetBytes("$subId|$rg")
$sha    = [System.Security.Cryptography.SHA256]::Create()
$hash   = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
$acrName = ("acrhrmcp" + $hash.Substring(0,18)).ToLower()

Write-Host "ACR Name: $acrName" -ForegroundColor Cyan

$acrExists = & az acr show -g $rg -n $acrName --query name -o tsv 2>$null
if (-not $acrExists) {
  Write-Host "Creating ACR..." -ForegroundColor Yellow
  & az acr create -g $rg -n $acrName -l $rgLocation --sku Basic --admin-enabled true --only-show-errors | Out-Null
} else {
  # Ensure admin creds are enabled because the Bicep uses listCredentials() to configure Container Apps registry auth
  & az acr update -g $rg -n $acrName --admin-enabled true --only-show-errors | Out-Null
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

# Make sure build context has a csproj (otherwise ACR build will fail later)
$csproj = Get-ChildItem -Path $McpSourcePath -Filter *.csproj -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $csproj) {
  Fail "No *.csproj found in $McpSourcePath. The Docker build context must include the app source, not just the Dockerfile."
}

# -------------------------
# Build image in ACR (no Docker needed)
# -------------------------
$repo = "hr-mcp-server"

$qTags = "[?@=='$ImageTag'] | length(@)"
$tagCount = & az acr repository show-tags -n $acrName --repository $repo --query $qTags -o tsv 2>$null

if ($tagCount -ne "1") {
  Write-Host "Building container image in ACR (this can take a few minutes)..." -ForegroundColor Yellow
  Push-Location $McpSourcePath
  & az acr build -r $acrName -t "${repo}:${ImageTag}" . --only-show-errors
  Pop-Location
} else {
  Write-Host "Image already exists: ${repo}:${ImageTag} (skipping build)" -ForegroundColor Green
}

# -------------------------
# Deploy Bicep (MCP-only template)
# -------------------------
$bicepUrl  = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/AzureTemplates/LAB565.bicep"
$bicepPath = Join-Path $env:TEMP "LAB565.bicep"

Write-Host "Downloading Bicep..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $bicepUrl -OutFile $bicepPath

Write-Host "Validating Bicep..." -ForegroundColor Yellow
& az bicep build --file $bicepPath | Out-Null

$mcpKey = [guid]::NewGuid().ToString("N")
$deploymentName = "deployment"

Write-Host "Deploying resources..." -ForegroundColor Yellow
& az deployment group create `
  --name $deploymentName `
  --resource-group $rg `
  --template-file $bicepPath `
  --parameters `
      location="$rgLocation" `
      acrResourceGroup="$rg" `
      acrName="$acrName" `
      mcpImageTag="$ImageTag" `
      mcpApiKey="$mcpKey" `
  --only-show-errors

# -------------------------
# Output student copy/paste values
# -------------------------
$mcpBaseUrl = (& az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpBaseUrl.value" -o tsv --only-show-errors).Trim()
$mcpHeader  = (& az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpHeaderName.value" -o tsv --only-show-errors).Trim()

""
"==== STUDENT COPY/PASTE ===="
"MCP Base URL : $mcpBaseUrl"
"Header Name : $mcpHeader"
"API Key     : $mcpKey"
"==========================="
""

# -------------------------
# Write student copy/paste to a Desktop file (MCP_Info.txt)
# -------------------------
$desktop = Get-DesktopPath
$outFile = Join-Path $desktop "MCP_Info.txt"

$content = @(
  "==== STUDENT COPY/PASTE ===="
  "MCP Base URL : $mcpBaseUrl"
  "Header Name : $mcpHeader"
  "API Key     : $mcpKey"
  "==========================="
)

Set-Content -Path $outFile -Value $content -Encoding UTF8 -Force

Write-Host "Wrote MCP info file to: $outFile" -ForegroundColor Green
