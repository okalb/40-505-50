<# 
Deploy-LAB565.ps1 (student-run)
- Uses existing RG: RG1 (no discovery/prompting)
- Prompts interactive az login only when required
- Ensures ACR exists + admin enabled
- ACR cloud build
- Deploys MCP-only Bicep
- Writes MCP_Info.txt to Desktop
- Writes a log file to C:\labs\deploy for troubleshooting
#>

[CmdletBinding()]
param(
  [string]$RepoOwner = "okalb",
  [string]$RepoName  = "40-505-50",
  [string]$Branch    = "main",

  # Keep param for compatibility, but ignored unless you want to override later
  [string]$ResourceGroupName = "RG1",

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
  # Try to fetch a management plane token (strong login signal)
  $token = & az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $token) {
    Write-Host "Signing into Azure (interactive)..." -ForegroundColor Yellow

    # Browser login (default). Switch to --use-device-code if your lab browser auth is flaky.
    & az login --only-show-errors | Out-Null
    # & az login --use-device-code --only-show-errors | Out-Null

    $token = & az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) {
      Fail "Azure CLI login did not complete successfully."
    }
  }

  # Ensure there is an active subscription context
  $subId = & az account show --query id -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $subId) {
    Fail "Azure CLI has no active subscription context. Use: az account list, then az account set -s <subscriptionId>."
  }
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

# -------------------------
# Logging to a file (helps when users double-click / right-click)
# -------------------------
$logDir = "C:\labs\deploy"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath = Join-Path $logDir ("Deploy-LAB565_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $logPath -Append | Out-Null

try {
  Require-AzCli

  # Reduce noise
  & az config set core.only_show_errors=yes --only-show-errors | Out-Null

  Ensure-LoggedIn

  # Always use RG1 (or ResourceGroupName param defaulting to RG1)
  $rg = $ResourceGroupName.Trim()
  if (-not $rg) { $rg = "RG1" }

  $rgExists = & az group exists -n $rg --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) { Fail "Failed to check if resource group '$rg' exists." }
  if ($rgExists -ne "true") { Fail "Resource group '$rg' does not exist. Ensure RG1 exists before running." }

  Write-Host "Using Resource Group: $rg" -ForegroundColor Cyan

  $rgLocation = & az group show -n $rg --query location -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $rgLocation) { Fail "Failed to resolve location for resource group '$rg'." }
  $rgLocation = $rgLocation.Trim()
  Write-Host "RG Location: $rgLocation" -ForegroundColor Cyan

  # Providers
  Ensure-ProviderRegistered "Microsoft.App"
  Ensure-ProviderRegistered "Microsoft.ContainerRegistry"

  # -------------------------
  # ACR in same RG
  # -------------------------
  $subId = & az account show --query id -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $subId) { Fail "Failed to read subscription id from Azure CLI." }
  $subId = $subId.Trim()

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

  # Confirm build context has a csproj
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
    Write-Host "Building container image in ACR..." -ForegroundColor Yellow
    Push-Location $McpSourcePath
    & az acr build -r $acrName -t "${repo}:${ImageTag}" . --only-show-errors
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
    --only-show-errors | Out-Null

  # -------------------------
  # Outputs
  # -------------------------
  $mcpBaseUrl = & az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpBaseUrl.value" -o tsv --only-show-errors 2>$null
  $mcpHeader  = & az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpHeaderName.value" -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $mcpBaseUrl -or -not $mcpHeader) { Fail "Failed to read deployment outputs." }

  $mcpBaseUrl = $mcpBaseUrl.Trim()
  $mcpHeader  = $mcpHeader.Trim()

  ""
  "==== STUDENT COPY/PASTE ===="
  "MCP Base URL : $mcpBaseUrl"
  "Header Name : $mcpHeader"
  "API Key     : $mcpKey"
  "==========================="
  ""

  # Write to Desktop
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
  Write-Host "Log file: $logPath" -ForegroundColor Cyan
}
catch {
  Write-Host ""
  Write-Host "Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Log file: $logPath" -ForegroundColor Yellow
  Write-Host "If you launched this by right-clicking, use the CMD wrapper so the window stays open." -ForegroundColor Yellow
  throw
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
}
