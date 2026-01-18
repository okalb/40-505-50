<# 
Deploy-LAB565.ps1 (student-run)
- Interactive az login
- Choose/find target RG
- Ensure ACR exists (in same RG)
- Download Dockerfile/.dockerignore into C:\labs\hr-mcp-server
- ACR cloud build (no Docker required)
- Deploy Bicep
- Print MCP URL + header + API key
- Quick smoke test
#>

[CmdletBinding()]
param(
  [string]$RepoOwner = "okalb",
  [string]$RepoName  = "40-505-50",
  [string]$Branch    = "main",

  # Optional: specify RG explicitly to avoid ambiguity
  [string]$ResourceGroupName = "",

  # Optional: if Entra lookup is blocked, instructor can provide this
  [string]$LabUserObjectId = "",

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
  try { az account show --only-show-errors | Out-Null }
  catch {
    Write-Host "Signing into Azure (interactive)..." -ForegroundColor Yellow
    az login --only-show-errors | Out-Null
  }
}

function Resolve-ResourceGroup {
  param([string]$Rg)

  if ($Rg) { return $Rg }

  $matches = az group list --query "[?contains(name,'LAB565')].name" -o tsv --only-show-errors
  if (-not $matches) {
    Fail "Couldn't auto-find a resource group containing 'LAB565'. Re-run with -ResourceGroupName <name>."
  }

  $list = @($matches | ForEach-Object { $_.Trim() } | Where-Object { $_ })

  if ($list.Count -eq 1) { return $list[0] }

  # Try best guess: prefer something that looks like the lab RG
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

function Resolve-UserObjectId {
  param([string]$Override)

  if ($Override) { return $Override.Trim() }

  # Attempt 1: signed-in-user (best)
  try {
    $id = (az ad signed-in-user show --query id -o tsv 2>$null).Trim()
    if ($id) { return $id }
  } catch {}

  # Attempt 2: account UPN -> user show
  try {
    $upn = (az account show --query user.name -o tsv 2>$null).Trim()
    if ($upn) {
      $id = (az ad user show --id $upn --query id -o tsv 2>$null).Trim()
      if ($id) { return $id }
    }
  } catch {}

  return ""
}

# -------------------------
# Start
# -------------------------
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
  az acr build -r $acrName -t "${repo}:${ImageTag}" . --only-show-errors
  Pop-Location
} else {
  Write-Host "Image already exists: ${repo}:${ImageTag} (skipping build)" -ForegroundColor Green
}

# -------------------------
# Deploy Bicep
# -------------------------
$bicepUrl  = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/AzureTemplates/LAB565.bicep"
$bicepPath = Join-Path $env:TEMP "LAB565.bicep"

Write-Host "Downloading Bicep..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $bicepUrl -OutFile $bicepPath

$userObjectId = Resolve-UserObjectId $LabUserObjectId
if (-not $userObjectId) {
  Write-Host ""
  Write-Host "ERROR: Couldn't determine your Entra user Object ID." -ForegroundColor Red
  Write-Host "This is required because the Bicep assigns roles to the lab user." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Fix options:" -ForegroundColor Cyan
  Write-Host "  1) Re-run the script with: -LabUserObjectId <GUID>" -ForegroundColor Cyan
  Write-Host "  2) Or remove the 'LAB USER ROLE ASSIGNMENTS' section from the Bicep if not needed." -ForegroundColor Cyan
  Write-Host ""
  Fail "Missing labUserObjectId"
}

$mcpKey = [guid]::NewGuid().ToString("N")
$deploymentName = "deployment"

Write-Host "Deploying resources..." -ForegroundColor Yellow
az deployment group create `
  --name $deploymentName `
  --resource-group $rg `
  --template-file $bicepPath `
  --parameters `
      labUserObjectId="$userObjectId" `
      location="$rgLocation" `
      acrResourceGroup="$rg" `
      acrName="$acrName" `
      mcpImageTag="$ImageTag" `
      mcpApiKey="$mcpKey" `
  --only-show-errors

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

# -------------------------
# Quick smoke test (optional but helpful)
# -------------------------
Write-Host "Testing MCP URL..." -ForegroundColor Yellow
try {
  $r = Invoke-WebRequest -Uri $mcpBaseUrl -UseBasicParsing -TimeoutSec 20
  Write-Host "MCP responded (HTTP $($r.StatusCode))." -ForegroundColor Green
} catch {
  Write-Host "MCP test call failed (this can be normal if API key enforcement returns 401)." -ForegroundColor Yellow
  if ($_.Exception.Response) {
    $code = [int]$_.Exception.Response.StatusCode
    Write-Host "HTTP $code" -ForegroundColor Yellow
  } else {
    Write-Host $_.Exception.Message -ForegroundColor Yellow
  }
  Write-Host "If you see 502/503, check Container App logs (likely port mismatch)." -ForegroundColor Yellow
}
