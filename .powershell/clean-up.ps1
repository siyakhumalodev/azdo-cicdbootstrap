# --- Cleanup Script for Azure DevOps Project and Local Workspace
# This script removes the local project directory and the Azure DevOps project

param(
  [switch]$Force,
  [switch]$SkipConfirmation
)

# --- Load local variables/config
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$varsPath = Join-Path $ScriptRoot 'variables.ps1'
if (Test-Path $varsPath) {
  . $varsPath
}

if (-not $Config) {
  throw "Config hashtable not defined. Please define `$Config in variables.ps1."
}

# Set values from variables.ps1
$OrgUrl   = $env:AZDO_ORG_URL
$Pat      = $env:AZDO_PAT
$Project  = $Config.ProjectName
$LocalDir = $LocalWorkspaceDir

Write-Host "=== Azure DevOps Cleanup Script ===" -ForegroundColor Cyan
Write-Host "Organization: $OrgUrl" -ForegroundColor Gray
Write-Host "Project: $Project" -ForegroundColor Gray
Write-Host "Local Directory: $LocalDir" -ForegroundColor Gray
Write-Host ""

# Validate must-haves
if ([string]::IsNullOrWhiteSpace($OrgUrl)) {
  throw "Organization URL not set. Please set `$env:AZDO_ORG_URL in variables.ps1"
}
if ([string]::IsNullOrWhiteSpace($Pat)) {
  throw "PAT not set. Please set `$env:AZDO_PAT in variables.ps1"
}
if ([string]::IsNullOrWhiteSpace($Project)) {
  throw "Project name not set. Please set ProjectName in `$Config in variables.ps1"
}

# Confirmation prompt
if (-not $SkipConfirmation) {
  Write-Host "WARNING: This will permanently delete:" -ForegroundColor Yellow
  Write-Host "  1. Azure DevOps Project: $Project" -ForegroundColor Yellow
  Write-Host "  2. Local Directory: $LocalDir" -ForegroundColor Yellow
  Write-Host ""
  $confirmation = Read-Host "Type 'DELETE' to confirm deletion"
  
  if ($confirmation -ne 'DELETE') {
    Write-Host "Cleanup cancelled." -ForegroundColor Cyan
    exit 0
  }
}

Write-Host ""

# --- Configure Azure DevOps CLI
Write-Host "[1/3] Configuring Azure DevOps CLI..." -ForegroundColor Yellow
az devops configure --defaults organization=$OrgUrl 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to configure Azure DevOps CLI" -ForegroundColor Red
  throw "Azure DevOps CLI configuration failed"
}
$env:AZURE_DEVOPS_EXT_PAT = $Pat
Write-Host "[OK] Azure DevOps CLI configured" -ForegroundColor Green
Write-Host ""

# --- Delete Azure DevOps Project
Write-Host "[2/3] Deleting Azure DevOps project..." -ForegroundColor Yellow
$projectExists = az devops project show --project "$Project" --only-show-errors 2>$null
if ($projectExists) {
  Write-Host "  Found project '$Project', deleting..." -ForegroundColor Gray
  
  # Get project ID
  $projectObj = $projectExists | ConvertFrom-Json
  $projectId = $projectObj.id
  
  # Delete the project
  $deleteResult = az devops project delete --id $projectId --yes 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to delete project: $deleteResult" -ForegroundColor Red
    if (-not $Force) {
      throw "Project deletion failed"
    }
  } else {
    Write-Host "[OK] Azure DevOps project deleted" -ForegroundColor Green
  }
} else {
  Write-Host "[SKIP] Project '$Project' not found in Azure DevOps" -ForegroundColor Yellow
}
Write-Host ""

# --- Delete Local Directory
Write-Host "[3/3] Deleting local project directory..." -ForegroundColor Yellow
if ([string]::IsNullOrWhiteSpace($LocalDir)) {
  Write-Host "[SKIP] Local directory path not specified in variables.ps1" -ForegroundColor Yellow
} elseif (Test-Path $LocalDir) {
  Write-Host "  Deleting: $LocalDir" -ForegroundColor Gray
  try {
    Remove-Item -Path $LocalDir -Recurse -Force -ErrorAction Stop
    Write-Host "[OK] Local directory deleted" -ForegroundColor Green
  } catch {
    Write-Host "[ERROR] Failed to delete local directory: $_" -ForegroundColor Red
    if (-not $Force) {
      throw "Local directory deletion failed"
    }
  }
} else {
  Write-Host "[SKIP] Local directory does not exist: $LocalDir" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "=== Cleanup Complete ===" -ForegroundColor Cyan
Write-Host "Project '$Project' and local directory have been removed." -ForegroundColor Green
