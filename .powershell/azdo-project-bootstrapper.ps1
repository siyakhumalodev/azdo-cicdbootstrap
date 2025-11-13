# --- #https://learn.microsoft.com/en-us/azure/devops/cli/?view=azure-devops

param(
  [string]$OrgUrl,
  [string]$Pat,
  [string]$Project,
  [string]$Repo,
  [string]$PipeName
)

# --- Load local variables/config if present
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$varsPath = Join-Path $ScriptRoot 'variables.ps1'
if (Test-Path $varsPath) {
  . $varsPath
}

if (-not $Config) {
  throw "Config hashtable not defined. Please define `$Config in variables.ps1."
}

# Set values from variables.ps1 if not provided as parameters
if ([string]::IsNullOrWhiteSpace($OrgUrl))   { $OrgUrl   = $env:AZDO_ORG_URL }
if ([string]::IsNullOrWhiteSpace($Pat))      { $Pat      = $env:AZDO_PAT }
if ([string]::IsNullOrWhiteSpace($Project))  { $Project  = $Config.ProjectName }
if ([string]::IsNullOrWhiteSpace($PipeName)) { $PipeName = $Config.PipelineName }

# Use default repo (same name as project) if not specified
if ([string]::IsNullOrWhiteSpace($Repo))     { $Repo = $Project }

Write-Host "=== Azure DevOps CI/CD Setup Script ===" -ForegroundColor Cyan
Write-Host "Organization: $OrgUrl" -ForegroundColor Gray
Write-Host "Project: $Project" -ForegroundColor Gray
Write-Host "Repository: $Repo" -ForegroundColor Gray
Write-Host "Pipeline: $PipeName" -ForegroundColor Gray
Write-Host ""

# Validate must-haves
foreach ($name in 'OrgUrl','Pat','Project','Repo','PipeName') {
  $value = Get-Variable -Name $name -ValueOnly
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required parameter/variable: $name. Provide it via variables.ps1, env vars, or -$name."
  }
}

# --- Auth for az devops
Write-Host "[1/12] Configuring Azure DevOps CLI..." -ForegroundColor Yellow
az devops configure --defaults organization=$OrgUrl
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to configure Azure DevOps CLI" -ForegroundColor Red
  throw "Azure DevOps CLI configuration failed"
}
$env:AZURE_DEVOPS_EXT_PAT = $Pat
Write-Host "[OK] Azure DevOps CLI configured" -ForegroundColor Green
Write-Host ""

# --- Ensure project exists
Write-Host "[2/12] Checking if project exists..." -ForegroundColor Yellow
$proj = az devops project show --project "$Project" --only-show-errors 2>$null
if (-not $proj) {
  Write-Host "  Creating project '$Project'..." -ForegroundColor Gray
  $createResult = az devops project create --name "$Project" --visibility private 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to create project" -ForegroundColor Red
    Write-Host "Error details: $createResult" -ForegroundColor Red
    throw "Project creation failed"
  }
  Write-Host "[OK] Project created" -ForegroundColor Green
} else {
  Write-Host "[OK] Project already exists" -ForegroundColor Green
}
Write-Host ""

az devops configure --defaults project="$Project"
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to set default project" -ForegroundColor Red
  throw "Failed to configure default project"
}

# --- Prompt user to create Service Connection
Write-Host ""
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host "IMPORTANT: Service Connection Required" -ForegroundColor Yellow
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Your Azure DevOps project has been created/confirmed." -ForegroundColor White
Write-Host "Please create a Service Connection for your CI/CD Pipeline." -ForegroundColor White
Write-Host ""
Write-Host "Expected Service Connection Name: " -NoNewline -ForegroundColor White
Write-Host "$($Config.ServiceConnection)" -ForegroundColor Cyan
Write-Host ""
Write-Host "To create the service connection:" -ForegroundColor Gray
Write-Host "  1. Go to: $OrgUrl/$Project/_settings/adminservices" -ForegroundColor Gray
Write-Host "  2. Click 'New service connection'" -ForegroundColor Gray
Write-Host "  3. Select 'Azure Resource Manager'" -ForegroundColor Gray
Write-Host "  4. Name it: $($Config.ServiceConnection)" -ForegroundColor Gray
Write-Host ""
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host ""

do {
  $response = Read-Host "Type 'Y' or 'Done' once the service connection has been created"
  $response = $response.Trim().ToLower()
} while ($response -ne 'y' -and $response -ne 'done')

Write-Host "[OK] Continuing with setup..." -ForegroundColor Green
Write-Host ""

# Reconfigure Azure DevOps CLI to refresh context after user interaction
Write-Host "  Refreshing Azure DevOps CLI context..." -ForegroundColor Gray
az devops configure --defaults organization=$OrgUrl project="$Project"
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to refresh Azure DevOps CLI context" -ForegroundColor Red
  throw "Failed to reconfigure Azure DevOps CLI"
}

# Verify the service connection exists
Write-Host "  Verifying service connection exists..." -ForegroundColor Gray
$serviceConnections = az devops service-endpoint list --project "$Project" --org "$OrgUrl" 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[WARNING] Could not retrieve service connections list" -ForegroundColor Yellow
} else {
  $serviceConnectionsObj = $serviceConnections | ConvertFrom-Json
  $targetConnection = $serviceConnectionsObj | Where-Object { $_.name -eq $Config.ServiceConnection }
  
  if ($targetConnection) {
    Write-Host "  [OK] Service connection '$($Config.ServiceConnection)' found (ID: $($targetConnection.id))" -ForegroundColor Green
  } else {
    Write-Host ""
    Write-Host "[ERROR] Service connection '$($Config.ServiceConnection)' not found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Available service connections:" -ForegroundColor Yellow
    if ($serviceConnectionsObj.Count -eq 0) {
      Write-Host "  (none)" -ForegroundColor Gray
    } else {
      $serviceConnectionsObj | ForEach-Object { 
        Write-Host "  - $($_.name) (Type: $($_.type))" -ForegroundColor Gray 
      }
    }
    Write-Host ""
    throw "Service connection '$($Config.ServiceConnection)' does not exist. Please create it before continuing."
  }
}
Write-Host ""

# --- Check if default repo exists (ADO creates one automatically with the project)
Write-Host "[3/12] Checking repository..." -ForegroundColor Yellow
$repoInfo = az repos show --repository "$Repo" 2>$null
if ($repoInfo) {
  Write-Host "[OK] Repository '$Repo' found" -ForegroundColor Green
} else {
  Write-Host "  Warning: Repository '$Repo' not found. ADO should have created a default repo." -ForegroundColor Red
  throw "Repository not found. Check project initialization."
}
Write-Host ""

# --- Local workspace
Write-Host "[4/12] Setting up local workspace..." -ForegroundColor Yellow
$work = if ($LocalWorkspaceDir) { $LocalWorkspaceDir } else { Join-Path $env:TEMP ("repo_" + [Guid]::NewGuid()) }
if (-not (Test-Path $work)) {
  Write-Host "  Creating directory: $work" -ForegroundColor Gray
  New-Item -ItemType Directory -Path $work | Out-Null
}
Set-Location $work
Write-Host "[OK] Working in: $work" -ForegroundColor Green
Write-Host ""

# Initialize git if not already a repo
Write-Host "[5/12] Initializing git repository..." -ForegroundColor Yellow
if (-not (Test-Path ".git")) {
  git init
  Write-Host "[OK] Git repository initialized" -ForegroundColor Green
} else {
  Write-Host "[OK] Git repository already initialized" -ForegroundColor Green
}
Write-Host ""

# --- .gitignore setup
Write-Host "[6/12] Configuring .gitignore..." -ForegroundColor Yellow
$gi = ".gitignore"
if (-not (Test-Path $gi)) { New-Item -Path $gi -ItemType File | Out-Null }

$ignoreLines = @'
# Local bootstrap/secret files
variables.ps1
variables.*.ps1
*.secrets.*
.env
.env.*
# OS/editor noise
.DS_Store
Thumbs.db
.vscode/
'@

# Append only the lines that aren't already present
$current = if (Test-Path $gi) { Get-Content $gi -Raw } else { "" }
if ($ignoreLines -notin $current) {
  Add-Content $gi $ignoreLines
}
Write-Host "[OK] .gitignore configured" -ForegroundColor Green
Write-Host ""

# --- Sample app placeholder
Write-Host "[7/12] Creating README..." -ForegroundColor Yellow
"## Demo Repo for PowerShell CI/CD" | Set-Content README.md
Write-Host "[OK] README.md created" -ForegroundColor Green
Write-Host ""

# Names to keep things consistent
$solutionName   = $Config.SolutionName
$webProjectName = $Config.WebProjectName
$apiProjectName = $Config.ApiProjectName

# 1) Create the solution
Write-Host "[8/12] Creating .NET solution and projects..." -ForegroundColor Yellow
Write-Host "  Creating solution: $solutionName" -ForegroundColor Gray
dotnet new sln -n $solutionName 2>$null

# 2) Create a Blazor Unified project (web front-end)
Write-Host "  Creating Blazor project: $webProjectName" -ForegroundColor Gray
dotnet new blazor -n $webProjectName --framework $Config.DotNetFramework 2>$null

# 3) Create a Web API project (API backend)
Write-Host "  Creating Web API project: $apiProjectName" -ForegroundColor Gray
dotnet new webapi -n $apiProjectName -f $Config.DotNetFramework 2>$null

# 4) Add both projects to the solution
Write-Host "  Adding projects to solution..." -ForegroundColor Gray
dotnet sln "$solutionName.sln" add `
  "$webProjectName\$webProjectName.csproj" `
  "$apiProjectName\$apiProjectName.csproj" 2>$null

Write-Host "[OK] .NET solution and projects created" -ForegroundColor Green
Write-Host ""

# Ensure .azure-pipelines directory exists
Write-Host "[9/12] Creating pipeline YAML..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path ".azure-pipelines" -Force | Out-Null

# --- YAML pipeline file (Development only) from template
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath     = Join-Path $ScriptRoot 'cicd-template.yml'
$pipelineFilePath = ".azure-pipelines/azure-pipeline.yml"

if (-not (Test-Path $templatePath)) {
  throw "YAML template not found at $templatePath"
}

$rawTemplate = Get-Content -Path $templatePath -Raw

$yaml = $rawTemplate `
  -replace '__DefaultBranch__',      [regex]::Escape($Config.DefaultBranch) `
  -replace '__VmImage__',            [regex]::Escape($Config.VmImage) `
  -replace '__BuildConfiguration__', [regex]::Escape($Config.BuildConfiguration) `
  -replace '__DotNetFramework__',    $Config.DotNetFramework `
  -replace '__DotNetVersion__',      $Config.DotNetVersion `
  -replace '__ServiceConnection__',  [regex]::Escape($Config.ServiceConnection) `
  -replace '__WebAppNameDev__',      [regex]::Escape($Config.WebAppNameDev) `
  -replace '__ApiAppNameDev__',      [regex]::Escape($Config.ApiAppNameDev) `
  -replace '__ResourceGroupDev__',   [regex]::Escape($Config.ResourceGroupDev) `
  -replace '__EnvironmentName__',    [regex]::Escape($Config.EnvironmentName)

$yaml | Set-Content $pipelineFilePath
Write-Host "[OK] Pipeline YAML created at $pipelineFilePath" -ForegroundColor Green
Write-Host ""

# --- Commit & push to ADO repo
Write-Host "[10/12] Committing and pushing code to Azure DevOps..." -ForegroundColor Yellow
Write-Host "  Staging files..." -ForegroundColor Gray
git add . 2>$null
Write-Host "  Committing..." -ForegroundColor Gray
git commit -m "Initial commit with Dev-only pipeline" 2>$null
$branch = $Config.DefaultBranch
Write-Host "  Setting branch to '$branch'..." -ForegroundColor Gray
git branch -M $branch 2>$null

# Get username from global git config
$gitUser = git config --global user.name
if ([string]::IsNullOrWhiteSpace($gitUser)) {
  Write-Host "  Warning: No git user.name configured globally. Using organization name as default." -ForegroundColor Yellow
  $orgName = ($OrgUrl -replace 'https://dev.azure.com/', '').TrimEnd('/')
  $gitUser = $orgName
}

# Replace spaces with dashes for URL compatibility
$gitUser = $gitUser -replace '\s+', '-'

Write-Host "  Git username: '$gitUser'" -ForegroundColor Cyan

# Build the authenticated remote URL
$orgName = ($OrgUrl -replace 'https://dev.azure.com/', '').TrimEnd('/')
$remoteWithPat = "https://${gitUser}:${Pat}@dev.azure.com/${orgName}/${Project}/_git/${Repo}"

# Show masked URL for debugging
$maskedUrl = "https://${gitUser}:****@dev.azure.com/${orgName}/${Project}/_git/${Repo}"
Write-Host "  Remote URL (masked): $maskedUrl" -ForegroundColor Cyan

# Remove existing origin if present
git remote remove origin 2>$null

Write-Host "  Adding remote origin..." -ForegroundColor Gray
git remote add origin $remoteWithPat
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to add remote origin" -ForegroundColor Red
  throw "Git remote add failed"
}

Write-Host "  Pushing to remote..." -ForegroundColor Gray
git push -u origin $branch
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to push code to Azure DevOps" -ForegroundColor Red
  throw "Git push failed"
}
Write-Host "[OK] Code pushed to Azure DevOps" -ForegroundColor Green
Write-Host ""

# --- Create pipeline
Write-Host "[11/12] Creating Azure Pipeline..." -ForegroundColor Yellow

# Verify we're in the correct project context before creating pipeline
Write-Host "  Verifying project context..." -ForegroundColor Gray
$currentProject = az devops project show --project "$Project" 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Cannot access project '$Project'" -ForegroundColor Red
  Write-Host "Error details: $currentProject" -ForegroundColor Red
  throw "Failed to verify project access. Please ensure you have permissions."
}
$projObj = $currentProject | ConvertFrom-Json
Write-Host "  Project Name: $($projObj.name)" -ForegroundColor Gray
Write-Host "  Project ID: $($projObj.id)" -ForegroundColor Gray

# First, check if pipeline already exists
$existingPipeline = az pipelines list --project "$Project" --query "[?name=='$PipeName'].id" -o tsv 2>$null
if ($existingPipeline) {
  Write-Host "  Pipeline '$PipeName' already exists (ID: $existingPipeline)" -ForegroundColor Yellow
  $pipelineId = $existingPipeline
} else {
  # Create new pipeline - explicitly specify project to avoid using wrong cached context
  $pipeResult = az pipelines create `
    --name "$PipeName" `
    --repository "$Repo" `
    --repository-type tfsgit `
    --branch $branch `
    --yml-path $pipelineFilePath `
    --project "$Project" `
    --org "$OrgUrl" `
    --skip-first-run true 2>&1

  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to create pipeline" -ForegroundColor Red
    Write-Host "Error details: $pipeResult" -ForegroundColor Red
    throw "Pipeline creation failed. Please check your permissions and project configuration."
  }

  # Display any warnings from the command
  $warnings = $pipeResult | Where-Object { $_ -match '^WARNING:' }
  if ($warnings) {
    Write-Host "  Warnings from pipeline creation:" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
  }

  # Extract JSON by finding the first line that starts with { and taking everything from there
  $resultString = $pipeResult -join "`n"
  $jsonStartIndex = $resultString.IndexOf('{')
  
  if ($jsonStartIndex -ge 0) {
    $jsonString = $resultString.Substring($jsonStartIndex)
  } else {
    Write-Host "[ERROR] No JSON found in pipeline creation response" -ForegroundColor Red
    Write-Host "Raw output: $pipeResult" -ForegroundColor Gray
    throw "Pipeline creation response does not contain valid JSON"
  }
  
  try {
    $pipe = $jsonString | ConvertFrom-Json
    $pipelineId = $pipe.id
  } catch {
    Write-Host "[ERROR] Failed to parse pipeline creation response" -ForegroundColor Red
    Write-Host "JSON attempted: $jsonString" -ForegroundColor Gray
    throw "Pipeline creation response parsing failed: $_"
  }
  
  if ([string]::IsNullOrWhiteSpace($pipelineId)) {
    Write-Host "[ERROR] Pipeline creation returned empty ID" -ForegroundColor Red
    Write-Host "Raw output: $pipeResult" -ForegroundColor Gray
    throw "Pipeline creation failed - no ID returned"
  }
  
  Write-Host "[OK] Pipeline '$PipeName' created (ID: $pipelineId)" -ForegroundColor Green
}
Write-Host ""

# --- Queue a run
Write-Host "[12/12] Queuing pipeline run..." -ForegroundColor Yellow
if ([string]::IsNullOrWhiteSpace($pipelineId)) {
  Write-Host "[ERROR] Cannot queue pipeline run - no pipeline ID available" -ForegroundColor Red
  throw "Invalid pipeline ID"
}

$runResult = az pipelines run --id $pipelineId --project "$Project" --org "$OrgUrl" 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Failed to queue pipeline run" -ForegroundColor Red
  Write-Host "Error details: $runResult" -ForegroundColor Red
  throw "Pipeline run failed to queue"
}

Write-Host "[OK] Pipeline run queued for Development environment" -ForegroundColor Green
Write-Host ""

Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host "Project URL: $OrgUrl/$Project" -ForegroundColor Gray
Write-Host "Repository: $OrgUrl/$Project/_git/$Repo" -ForegroundColor Gray
Write-Host "Pipeline: $OrgUrl/$Project/_build?definitionId=$pipelineId" -ForegroundColor Gray
