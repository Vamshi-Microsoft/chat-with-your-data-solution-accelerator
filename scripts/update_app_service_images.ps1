# update_app_service_images.ps1
#
# Updates the three CWYD App Services / Function App to use images from the
# per-deployment Azure Container Registry, and configures managed-identity
# based authentication for private-registry pulls.
#
# Prerequisites:
#   * Azure CLI logged in  (az login)
#   * Images already pushed to ACR  (run build_and_push_images.ps1 first)
#
# Usage:
#   .\scripts\update_app_service_images.ps1 -ResourceGroupName <rg> [-Tag <tag>]
#
# Parameters:
#   -ResourceGroupName   Azure resource group (mandatory)
#   -Tag                 Image tag to deploy (default: latest)

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"

# Auto-load environment values from .azure/<env>/.env when present
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$azureDir = Join-Path $RepoRoot '.azure'
if (Test-Path $azureDir) {
    $envFiles = Get-ChildItem -Path $azureDir -Recurse -Filter '.env' -File -ErrorAction SilentlyContinue
    foreach ($ef in $envFiles) {
        try {
            $lines = Get-Content $ef.FullName | Where-Object { $_ -and ($_ -match '=') }
            $kv = @{}
            foreach ($l in $lines) {
                if ($l -match '^\s*([A-Za-z0-9_]+)\s*=\s*"?(.*?)"?\s*$') { $kv[$matches[1]] = $matches[2] }
            }
            if ($kv.ContainsKey('ACR_NAME')) { $AcrName = $kv['ACR_NAME'] }
            if ($kv.ContainsKey('ACR_LOGIN_SERVER')) { $AcrLoginServer = $kv['ACR_LOGIN_SERVER'] }
            if ($kv.ContainsKey('SERVICE_WEB_RESOURCE_NAME')) { $ServiceWebName = $kv['SERVICE_WEB_RESOURCE_NAME'] }
            if ($kv.ContainsKey('SERVICE_ADMINWEB_RESOURCE_NAME')) { $ServiceAdminwebName = $kv['SERVICE_ADMINWEB_RESOURCE_NAME'] }
            if ($kv.ContainsKey('SERVICE_FUNCTION_RESOURCE_NAME')) { $ServiceFunctionName = $kv['SERVICE_FUNCTION_RESOURCE_NAME'] }
            if ($kv.ContainsKey('AZURE_RESOURCE_GROUP')) { $EnvResourceGroup = $kv['AZURE_RESOURCE_GROUP'] }
            if ($AcrName -or $ServiceWebName -or $ServiceAdminwebName -or $ServiceFunctionName) {
                Write-Host "Loaded env values from $($ef.FullName)"
                if ($AcrName) { Write-Host "  ACR_NAME=$AcrName" }
                if ($AcrLoginServer) { Write-Host "  ACR_LOGIN_SERVER=$AcrLoginServer" }
                if ($ServiceWebName) { Write-Host "  SERVICE_WEB_RESOURCE_NAME=$ServiceWebName" }
                if ($ServiceAdminwebName) { Write-Host "  SERVICE_ADMINWEB_RESOURCE_NAME=$ServiceAdminwebName" }
                if ($ServiceFunctionName) { Write-Host "  SERVICE_FUNCTION_RESOURCE_NAME=$ServiceFunctionName" }
                break
            }
        } catch {
            # ignore parse errors
        }
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host " CWYD - Update App Service container images"
Write-Host "  Resource group : $ResourceGroupName"
Write-Host "  Image tag      : $Tag"
Write-Host "============================================================"
Write-Host ""

# ---------------------------------------------------------------------------
# Discover shared resources
# ---------------------------------------------------------------------------
Write-Host "Discovering resources in resource group '$ResourceGroupName'..."

if (-not $AcrName) {
    $AcrName = az acr list `
        --resource-group $ResourceGroupName `
        --query "[0].name" `
        --output tsv 2>$null
}

if ([string]::IsNullOrWhiteSpace($AcrName)) {
    Write-Error "No Azure Container Registry found in resource group '$ResourceGroupName'.`nRun 'azd provision' to create infrastructure first."
    exit 1
}

if (-not $AcrLoginServer) {
    $AcrLoginServer = "$AcrName.azurecr.io"
}

$MiClientId = az identity list `
    --resource-group $ResourceGroupName `
    --query "[0].clientId" `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($MiClientId)) {
    Write-Error "No user-assigned managed identity found in resource group '$ResourceGroupName'."
    exit 1
}

$SubscriptionId = az account show --query id --output tsv

Write-Host "  ACR             : $AcrLoginServer"
Write-Host "  Managed identity: $MiClientId"
Write-Host ""

# ---------------------------------------------------------------------------
# Helper: update a web app
# ---------------------------------------------------------------------------
function Update-WebApp {
    param(
        [string]$AppName,
        [string]$ImageName
    )

    $FullImage = "${AcrLoginServer}/${ImageName}:${Tag}"
    Write-Host "  Updating App Service: $AppName"
    Write-Host "    Image: $FullImage"

    # 1. Set container image
    az webapp config container set `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --container-image-name $FullImage `
        --output none

    # 2. Set DOCKER_REGISTRY_SERVER_URL app setting
    az webapp config appsettings set `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --settings "DOCKER_REGISTRY_SERVER_URL=https://${AcrLoginServer}" `
        --output none

    # 3. Enable ACR pull with user-assigned managed identity
    $ResourceId = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Web/sites/${AppName}"
    az resource update `
        --ids $ResourceId `
        --set "properties.siteConfig.acrUseManagedIdentityCreds=true" `
        --set "properties.siteConfig.acrUserManagedIdentityID=$MiClientId" `
        --output none

    # 4. Restart to apply changes
    az webapp restart `
        --name $AppName `
        --resource-group $ResourceGroupName

    Write-Host "    Done."
}

# ---------------------------------------------------------------------------
# Helper: update a function app
# ---------------------------------------------------------------------------
function Update-FunctionApp {
    param(
        [string]$AppName,
        [string]$ImageName
    )

    $FullImage = "${AcrLoginServer}/${ImageName}:${Tag}"
    Write-Host "  Updating Function App: $AppName"
    Write-Host "    Image: $FullImage"

    # 1. Set DOCKER_REGISTRY_SERVER_URL app setting
    az functionapp config appsettings set `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --settings "DOCKER_REGISTRY_SERVER_URL=https://${AcrLoginServer}" `
        --output none

    # 2. Set the Linux custom container image and managed identity pull
    $ResourceId = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Web/sites/${AppName}"
    az resource update `
        --ids $ResourceId `
        --set "properties.siteConfig.linuxFxVersion=DOCKER|${FullImage}" `
        --set "properties.siteConfig.acrUseManagedIdentityCreds=true" `
        --set "properties.siteConfig.acrUserManagedIdentityID=$MiClientId" `
        --output none

    # 3. Restart
    az functionapp restart `
        --name $AppName `
        --resource-group $ResourceGroupName

    Write-Host "    Done."
}

# ---------------------------------------------------------------------------
# Discover and update each service
# ---------------------------------------------------------------------------
$ServiceImageMap = @{
    "web-docker"      = "rag-webapp"
    "adminweb-docker" = "rag-adminwebapp"
}

# -- Web apps --
Write-Host "Updating web App Services..."
foreach ($ServiceTag in @("web-docker", "adminweb-docker")) {
    $AppName = $null
    switch ($ServiceTag) {
        "web-docker"      { $AppName = $ServiceWebName }
        "adminweb-docker" { $AppName = $ServiceAdminwebName }
    }

    if ([string]::IsNullOrWhiteSpace($AppName)) {
        $AppListJson = az webapp list --resource-group $ResourceGroupName --output json 2>$null
        if (-not [string]::IsNullOrWhiteSpace($AppListJson)) {
            $apps = $AppListJson | ConvertFrom-Json
            $AppName = ($apps | Where-Object { $_.tags.'azd-service-name' -eq $ServiceTag } | Select-Object -First 1).name
        }
    }

    if ([string]::IsNullOrWhiteSpace($AppName)) {
        Write-Host "  WARNING: No App Service with tag azd-service-name='$ServiceTag' found - skipping."
        continue
    }

    Update-WebApp -AppName $AppName -ImageName $ServiceImageMap[$ServiceTag]
}

# -- Function App --
Write-Host ""
Write-Host "Updating Function App..."
$FuncAppName = $ServiceFunctionName
if (-not [string]::IsNullOrWhiteSpace($FuncAppName)) {
    Write-Host "  Using environment-provided Function App name: $FuncAppName"
} else {
    $FuncListJson = az functionapp list --resource-group $ResourceGroupName --output json 2>$null
    if (-not [string]::IsNullOrWhiteSpace($FuncListJson)) {
        $funcs = $FuncListJson | ConvertFrom-Json
        $FuncAppName = ($funcs | Where-Object { $_.tags.'azd-service-name' -eq 'function-docker' } | Select-Object -First 1).name
    }
}

if ([string]::IsNullOrWhiteSpace($FuncAppName)) {
    Write-Host "  WARNING: No Function App with tag azd-service-name='function-docker' found and no SERVICE_FUNCTION_RESOURCE_NAME was available - skipping."
} else {
    Update-FunctionApp -AppName $FuncAppName -ImageName "rag-backend"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host " Update complete!"
Write-Host "  Registry : https://${AcrLoginServer}"
Write-Host "  Tag      : ${Tag}"
Write-Host ""
Write-Host " Apps are restarting and will pull images from ACR."
Write-Host " Monitor health via Azure Portal or:"
Write-Host "   az webapp log tail --name <app-name> --resource-group $ResourceGroupName"
Write-Host "============================================================"
