# --- Azure DevOps org & auth
$env:AZDO_ORG_URL = "https://dev.azure.com/YOUR-ORG-NAME"
#https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate
$env:AZDO_PAT     = "YOUR-PERSONAL-ACCESS-TOKEN"

# --- New local workspace directory for solution creation (must not already exist)
$LocalWorkspaceDir = "c:\path\to\your\workspace"

# --- Central configuration used by the YAML template
$Config = @{
  # Project / pipeline bootstrap
  ProjectName        = "YOUR-PROJECT-NAME"
  # RepoName will default to ProjectName (ADO's default behavior)
  PipelineName       = "your-pipeline-name"

  # Git / pipeline
  DefaultBranch      = 'main'
  VmImage            = 'ubuntu-latest'

  # Build
  BuildConfiguration = 'Release'
  DotNetFramework    = 'net9.0'
  DotNetVersion      = '9.0.x'

  # Azure DevOps Service Connection
  ServiceConnection  = 'your-service-connection-name'

  # Azure resources (Dev)
  WebAppNameDev      = 'your-webapp-name-dev'
  ApiAppNameDev      = 'your-api-name-dev'
  ResourceGroupDev   = 'your-resource-group-name'
  HealthEndpoint    = "/health"

  # ADO Environment name
  EnvironmentName    = 'Development'

  # .NET solution / projects (what your script creates)
  SolutionName       = 'YourSolution'
  WebProjectName     = 'YourSolution.Web'
  ApiProjectName     = 'YourSolution.ApiService'
}
