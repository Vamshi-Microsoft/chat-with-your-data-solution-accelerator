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

$AcrName = az acr list `
    --resource-group $ResourceGroupName `
    --query "[0].name" `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($AcrName)) {
    Write-Error "No Azure Container Registry found in resource group '$ResourceGroupName'.`nRun 'azd provision' to create infrastructure first."
    exit 1
}

$AcrLoginServer = "$AcrName.azurecr.io"

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

    # 1. Set container image
    az functionapp config container set `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --image $FullImage `
        --registry-server "https://${AcrLoginServer}" `
        --output none

    # 2. Set DOCKER_REGISTRY_SERVER_URL app setting
    az functionapp config appsettings set `
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

    # 4. Restart
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
    $AppName = az webapp list `
        --resource-group $ResourceGroupName `
        --query "[?tags.""azd-service-name""=='$ServiceTag'].name | [0]" `
        --output tsv 2>$null

    if ([string]::IsNullOrWhiteSpace($AppName)) {
        Write-Host "  WARNING: No App Service with tag azd-service-name='$ServiceTag' found - skipping."
        continue
    }

    Update-WebApp -AppName $AppName -ImageName $ServiceImageMap[$ServiceTag]
}

# -- Function App --
Write-Host ""
Write-Host "Updating Function App..."
$FuncAppName = az functionapp list `
    --resource-group $ResourceGroupName `
    --query "[?tags.""azd-service-name""=='function-docker'].name | [0]" `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($FuncAppName)) {
    Write-Host "  WARNING: No Function App with tag azd-service-name='function-docker' found - skipping."
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
