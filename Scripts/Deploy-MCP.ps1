<# 
Deploy-MCP.ps1 (student-run)
- Uses existing RG: RG1 (no discovery/prompting)
- Prompts interactive az login only when required
- Ensures ACR exists + admin enabled
- ACR cloud build (no Docker required)
- Deploys MCP-only Bicep
- Writes MCP_Info.txt to Desktop
- Writes a log file to C:\labs\deploy for troubleshooting
- Closes the PowerShell window when done (success or failure)
#>

[CmdletBinding()]
param(
  [string]$RepoOwner = "okalb",
  [string]$RepoName  = "40-505-50",
  [string]$Branch    = "main",

  # Always use RG1 (you can override if you ever need to, but no discovery/prompting)
  [string]$ResourceGroupName = "RG1",

  [string]$McpSourcePath = "C:\labs\hr-mcp-server",
  [string]$ImageTag = "v1"
)

$ErrorActionPreference = "Stop"
$global:ExitCode = 0

function Fail([string]$msg) { throw $msg }

function Require-AzCli {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Fail "Azure CLI (az) is not installed or not on PATH."
  }
}

function Invoke-WebRequestSafe {
  param(
    [Parameter(Mandatory=$true)][string]$Uri,
    [Parameter(Mandatory=$true)][string]$OutFile
  )

  # PowerShell 5.1 sometimes needs TLS 1.2 explicitly, and -UseBasicParsing avoids IE dependencies.
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {}

  if ($PSVersionTable.PSVersion.Major -lt 6) {
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
  } else {
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile
  }
}

function Ensure-LoggedIn {
  # IMPORTANT: In Windows PowerShell, native stderr can become a terminating error when $ErrorActionPreference="Stop".
  # So we temporarily relax it for the token probe.
  $oldEAP = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $token = & az account get-access-token `
      --resource https://management.azure.com/ `
      --query accessToken -o tsv --only-show-errors 2>$null
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldEAP
  }

  if ($code -ne 0 -or -not $token) {
    Write-Host "Signing into Azure (interactive)..." -ForegroundColor Yellow
    & az login --only-show-errors | Out-Null

    # Re-check token (same safe pattern)
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $token = & az account get-access-token `
        --resource https://management.azure.com/ `
        --query accessToken -o tsv --only-show-errors 2>$null
      $code = $LASTEXITCODE
    }
    finally {
      $ErrorActionPreference = $oldEAP
    }

    if ($code -ne 0 -or -not $token) {
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

function Ensure-ProviderRegistered([string]$ns) {
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
# Logging (so failures are diagnosable even if the window closes)
# -------------------------
$logDir = "C:\labs\deploy"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath = Join-Path $logDir ("Deploy-MCP_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

Start-Transcript -Path $logPath -Append | Out-Null

try {
  Require-AzCli

  # Reduce noise
  & az config set core.only_show_errors=yes --only-show-errors | Out-Null

  Ensure-LoggedIn

  # Always use RG1 (no prompting)
  $rg = ($ResourceGroupName ?? "").Trim()
  if (-not $rg) { $rg = "RG1" }

  $rgExists = & az group exists -n $rg --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) { Fail "Failed to check if resource group '$rg' exists." }
  if ($rgExists -ne "true") { Fail "Resource group '$rg' does not exist. Ensure RG1 exists before running." }

  $rgLocation = & az group show -n $rg --query location -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $rgLocation) { Fail "Failed to resolve location for resource group '$rg'." }
  $rgLocation = $rgLocation.Trim()

  # Providers (may require subscription-level permissions)
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

  $acrExists = & az acr show -g $rg -n $acrName --query name -o tsv 2>$null
  if (-not $acrExists) {
    Write-Host "Creating ACR: $acrName" -ForegroundColor Yellow
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

  Invoke-WebRequestSafe -Uri $dockerfileUrl   -OutFile $dockerfilePath
  Invoke-WebRequestSafe -Uri $dockerignoreUrl -OutFile $dockerignorePath

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
  }

  # -------------------------
  # Deploy Bicep (MCP-only template)
  # -------------------------
  $bicepUrl  = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/AzureTemplates/LAB565.bicep"
  $bicepPath = Join-Path $env:TEMP "LAB565.bicep"

  Invoke-WebRequestSafe -Uri $bicepUrl -OutFile $bicepPath
  & az bicep build --file $bicepPath | Out-Null

  $mcpKey = [guid]::NewGuid().ToString("N")
  $deploymentName = "deployment"

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
  # Read outputs + write Desktop file (success signal)
  # -------------------------
  $mcpBaseUrl = & az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpBaseUrl.value" -o tsv --only-show-errors 2>$null
  $mcpHeader  = & az deployment group show -g $rg -n $deploymentName --query "properties.outputs.mcpHeaderName.value" -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $mcpBaseUrl -or -not $mcpHeader) { Fail "Failed to read deployment outputs." }

  $desktop = Get-DesktopPath
  $outFile = Join-Path $desktop "MCP_Info.txt"

  $content = @(
    "==== STUDENT COPY/PASTE ===="
    ("MCP Base URL : {0}" -f $mcpBaseUrl.Trim())
    ("Header Name : {0}" -f $mcpHeader.Trim())
    ("API Key     : {0}" -f $mcpKey)
    "==========================="
  )
  Set-Content -Path $outFile -Value $content -Encoding UTF8 -Force

  Write-Host "Deployment complete. MCP_Info.txt written to Desktop." -ForegroundColor Green
  Write-Host "Log file: $logPath" -ForegroundColor Cyan
}
catch {
  $global:ExitCode = 1
  Write-Host ""
  Write-Host "Deployment finished with errors." -ForegroundColor Red
  Write-Host "Log file: $logPath" -ForegroundColor Yellow
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
}

# Always close the PowerShell window/process when done
exit $global:ExitCode
