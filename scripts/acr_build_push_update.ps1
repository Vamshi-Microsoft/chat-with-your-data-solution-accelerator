<#
.SYNOPSIS
    Builds the application container images, pushes them to the per-deployment ACR, and updates the App Services / Function App.
.DESCRIPTION
    Runs the full ACR workflow for container-based deployments.
.PARAMETER ResourceGroupName
    The name of the Azure resource group containing the deployed resources.
.PARAMETER Mode
    Build mode: 'remote' (default) or 'local'.
.PARAMETER Tag
    Image tag to apply. Defaults to 'latest'.
.EXAMPLE
    .\scripts\acr_build_push_update.ps1 -ResourceGroupName "rg-cwyd-dev"
.EXAMPLE
    .\scripts\acr_build_push_update.ps1 -ResourceGroupName "rg-cwyd-dev" -Mode local -Tag v1.0.0
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("remote", "local")]
    [string]$Mode = "remote",

    [Parameter(Mandatory = $false)]
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 > $null 2>$null } catch {}
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AzArgs)
    $output = & az @AzArgs
    if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs -join ' ') failed with exit code $LASTEXITCODE" }
    return $output
}

function Load-AzureEnvValues {
    param([string]$Root)
    $azureDir = Join-Path $Root '.azure'
    if (-not (Test-Path $azureDir)) { return $null }

    $envFiles = Get-ChildItem -Path $azureDir -Recurse -Filter '.env' -File -ErrorAction SilentlyContinue
    foreach ($ef in $envFiles) {
        try {
            $lines = Get-Content $ef.FullName | Where-Object { $_ -and ($_ -match '=') }
            $kv = @{}
            foreach ($l in $lines) {
                if ($l -match '^[ \t]*([A-Za-z0-9_]+)[ \t]*=[ \t]*"?(.*?)"?[ \t]*$') {
                    $kv[$matches[1]] = $matches[2]
                }
            }

            if ($kv.ContainsKey('ACR_NAME') -or $kv.ContainsKey('ACR_LOGIN_SERVER')) {
                $kv['__LoadedFile'] = $ef.FullName
                return $kv
            }
        } catch {
            # ignore parse errors
        }
    }

    return $null
}

function Get-DeploymentOutput {
    param(
        [string]$DeploymentName,
        [string]$OutputKey
    )
    try {
        $value = Invoke-Az deployment group show --resource-group $ResourceGroupName --name $DeploymentName --query "properties.outputs.$OutputKey.value" -o tsv
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq 'None') { return $null }
        return $value
    } catch {
        return $null
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$envValues = Load-AzureEnvValues -Root $RepoRoot
if ($envValues) {
    $loadedFile = $envValues['__LoadedFile']
    Write-Host "Loaded environment values from $loadedFile"
    if ($envValues.ContainsKey('ACR_NAME')) { $AcrName = $envValues['ACR_NAME'] }
    if ($envValues.ContainsKey('ACR_LOGIN_SERVER')) { $AcrLoginServer = $envValues['ACR_LOGIN_SERVER'] }
    if ($envValues.ContainsKey('SERVICE_WEB_RESOURCE_NAME')) { $ServiceWebName = $envValues['SERVICE_WEB_RESOURCE_NAME'] }
    if ($envValues.ContainsKey('SERVICE_ADMINWEB_RESOURCE_NAME')) { $ServiceAdminwebName = $envValues['SERVICE_ADMINWEB_RESOURCE_NAME'] }
    if ($envValues.ContainsKey('SERVICE_FUNCTION_RESOURCE_NAME')) { $ServiceFunctionName = $envValues['SERVICE_FUNCTION_RESOURCE_NAME'] }
    if ($AcrName) { Write-Host "  ACR_NAME=$AcrName" }
    if ($AcrLoginServer) { Write-Host "  ACR_LOGIN_SERVER=$AcrLoginServer" }
    if ($ServiceWebName) { Write-Host "  SERVICE_WEB_RESOURCE_NAME=$ServiceWebName" }
    if ($ServiceAdminwebName) { Write-Host "  SERVICE_ADMINWEB_RESOURCE_NAME=$ServiceAdminwebName" }
    if ($ServiceFunctionName) { Write-Host "  SERVICE_FUNCTION_RESOURCE_NAME=$ServiceFunctionName" }
}

Write-Host "=============================================="
Write-Host " ACR Build, Push & Update"
Write-Host " Resource Group : $ResourceGroupName"
Write-Host " Mode           : $Mode"
Write-Host " Image Tag      : $Tag"
Write-Host " Repo Root      : $RepoRoot"
Write-Host "=============================================="
Write-Host ""

$DeploymentName = $null
try { $DeploymentName = Invoke-Az deployment group list --resource-group $ResourceGroupName --query "[0].name" -o tsv } catch { $DeploymentName = $null }
if (-not [string]::IsNullOrWhiteSpace($DeploymentName)) {
    Write-Host "Reading deployment outputs from deployment '$DeploymentName'..."
    if (-not $AcrName) { $AcrName = Get-DeploymentOutput -DeploymentName $DeploymentName -OutputKey 'ACR_NAME' }
    if (-not $AcrLoginServer) { $AcrLoginServer = Get-DeploymentOutput -DeploymentName $DeploymentName -OutputKey 'ACR_LOGIN_SERVER' }
    if (-not $MiClientId) { $MiClientId = Get-DeploymentOutput -DeploymentName $DeploymentName -OutputKey 'MANAGED_IDENTITY_CLIENT_ID' }
    if (-not $ServiceWebName) { $ServiceWebName = Get-DeploymentOutput -DeploymentName $DeploymentName -OutputKey 'SERVICE_WEB_RESOURCE_NAME' }
    if (-not $ServiceAdminwebName) { $ServiceAdminwebName = Get-DeploymentOutput -DeploymentName $DeploymentName -OutputKey 'SERVICE_ADMINWEB_RESOURCE_NAME' }
    if (-not $ServiceFunctionName) { $ServiceFunctionName = Get-DeploymentOutput -DeploymentName $DeploymentName -OutputKey 'SERVICE_FUNCTION_RESOURCE_NAME' }
}

if (-not $AcrName -and $AcrLoginServer) {
    if ($AcrLoginServer -match '^(.*)\.azurecr\.io$') { $AcrName = $matches[1] }
}

if ([string]::IsNullOrWhiteSpace($AcrName)) {
    Write-Host "Discovering Azure Container Registry..."
    try { $AcrName = Invoke-Az acr list --resource-group $ResourceGroupName --query "[0].name" -o tsv } catch { $AcrName = $null }
}

if ([string]::IsNullOrWhiteSpace($AcrName) -or $AcrName -eq 'None') {
    Write-Error "No Azure Container Registry found in resource group '$ResourceGroupName'.`nMake sure 'azd provision' has completed successfully."
    exit 1
}

if (-not $AcrLoginServer) { $AcrLoginServer = "${AcrName}.azurecr.io" }
Write-Host "  OK ACR found: $AcrName ($AcrLoginServer)"

$Images = @(
    @{ Name = "rag-webapp";      Dockerfile = "docker\Frontend.Dockerfile" },
    @{ Name = "rag-adminwebapp"; Dockerfile = "docker\Admin.Dockerfile"    },
    @{ Name = "rag-backend";     Dockerfile = "docker\Backend.Dockerfile"  }
)

Write-Host ""
if ($Mode -eq 'local') {
    Write-Host "--- LOCAL BUILD (Docker daemon) ---"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error "Docker is not installed or not in PATH.`nInstall Docker Desktop or use '-Mode remote' instead."
        exit 1
    }

    docker info 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker daemon is not running. Start Docker Desktop and retry."
        exit 1
    }

    Write-Host "Logging in to ACR '$AcrName'..."
    Invoke-Az acr login --name $AcrName

    foreach ($img in $Images) {
        $FullTag = "${AcrLoginServer}/$($img.Name):${Tag}"
        $Dockerfile = Join-Path $RepoRoot $img.Dockerfile

        Write-Host ""
        Write-Host "[$($img.Name)] Building from $($img.Dockerfile) ..."
        docker build --file $Dockerfile --tag $FullTag $RepoRoot
        if ($LASTEXITCODE -ne 0) { Write-Error "Build failed for $($img.Name)."; exit 1 }

        Write-Host "[$($img.Name)] Pushing $FullTag ..."
        docker push $FullTag
        if ($LASTEXITCODE -ne 0) { Write-Error "Push failed for $($img.Name)."; exit 1 }

        Write-Host "[$($img.Name)] OK Done"
    }
}
else {
    Write-Host "--- REMOTE BUILD (ACR Tasks - no local Docker required) ---"
    Write-Host "    Note: your Azure identity needs Contributor or AcrPush access on the ACR."
    Write-Host ""

    foreach ($img in $Images) {
        $FullTag = "$($img.Name):${Tag}"
        $Dockerfile = Join-Path $RepoRoot $img.Dockerfile

        Write-Host "[$($img.Name)] Submitting remote build to ACR '$AcrName' ..."
        Invoke-Az acr build --registry $AcrName --image $FullTag --file $Dockerfile $RepoRoot
        Write-Host "[$($img.Name)] OK Done"
    }
}

Write-Host ""
Write-Host "Updating App Services to use the new ACR images..."

if (-not $MiClientId) {
    Write-Host "Discovering managed identity..."
    try { $MiClientId = Invoke-Az identity list --resource-group $ResourceGroupName --query "[0].clientId" --output tsv } catch { $MiClientId = $null }
}

if ([string]::IsNullOrWhiteSpace($MiClientId)) {
    Write-Error "No user-assigned managed identity found in resource group '$ResourceGroupName'."
    exit 1
}

$SubscriptionId = Invoke-Az account show --query id --output tsv

function Update-WebApp {
    param(
        [string]$AppName,
        [string]$ImageName
    )

    $FullImage = "${AcrLoginServer}/${ImageName}:${Tag}"
    Write-Host "  Updating App Service: $AppName"
    Write-Host "    Image: $FullImage"

    Invoke-Az webapp config container set --name $AppName --resource-group $ResourceGroupName --container-image-name $FullImage --output none
    Invoke-Az webapp config appsettings set --name $AppName --resource-group $ResourceGroupName --settings "DOCKER_REGISTRY_SERVER_URL=https://${AcrLoginServer}" --output none

    $ResourceId = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Web/sites/${AppName}"
    Invoke-Az resource update --ids $ResourceId --set "properties.siteConfig.acrUseManagedIdentityCreds=true" --set "properties.siteConfig.acrUserManagedIdentityID=$MiClientId" --output none
    Invoke-Az webapp restart --name $AppName --resource-group $ResourceGroupName

    Write-Host "    Done."
}

function Update-FunctionApp {
    param(
        [string]$AppName,
        [string]$ImageName
    )

    $FullImage = "${AcrLoginServer}/${ImageName}:${Tag}"
    Write-Host "  Updating Function App: $AppName"
    Write-Host "    Image: $FullImage"

    Invoke-Az functionapp config appsettings set --name $AppName --resource-group $ResourceGroupName --settings "DOCKER_REGISTRY_SERVER_URL=https://${AcrLoginServer}" --output none
    $ResourceId = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Web/sites/${AppName}"
    Invoke-Az resource update --ids $ResourceId --set "properties.siteConfig.linuxFxVersion=DOCKER|${FullImage}" --set "properties.siteConfig.acrUseManagedIdentityCreds=true" --set "properties.siteConfig.acrUserManagedIdentityID=$MiClientId" --output none
    Invoke-Az functionapp restart --name $AppName --resource-group $ResourceGroupName

    Write-Host "    Done."
}

$ServiceImageMap = @{ "web-docker" = "rag-webapp"; "adminweb-docker" = "rag-adminwebapp" }

Write-Host "Updating web App Services..."
foreach ($ServiceTag in @('web-docker', 'adminweb-docker')) {
    $AppName = $null
    switch ($ServiceTag) {
        'web-docker'      { $AppName = $ServiceWebName }
        'adminweb-docker' { $AppName = $ServiceAdminwebName }
    }

    if ([string]::IsNullOrWhiteSpace($AppName)) {
        $appListJson = Invoke-Az webapp list --resource-group $ResourceGroupName --output json
        $apps = $appListJson | ConvertFrom-Json
        $AppName = ($apps | Where-Object { $_.tags.'azd-service-name' -eq $ServiceTag } | Select-Object -First 1).name
    }

    if ([string]::IsNullOrWhiteSpace($AppName)) {
        Write-Host "  WARNING: No App Service with tag azd-service-name='$ServiceTag' found - skipping."
        continue
    }

    Update-WebApp -AppName $AppName -ImageName $ServiceImageMap[$ServiceTag]
}

Write-Host ""
Write-Host "Updating Function App..."
if (-not [string]::IsNullOrWhiteSpace($ServiceFunctionName)) {
    Write-Host "  Using environment-provided Function App name: $ServiceFunctionName"
    $FuncAppName = $ServiceFunctionName
} else {
    $funcListJson = Invoke-Az functionapp list --resource-group $ResourceGroupName --output json
    $funcs = $funcListJson | ConvertFrom-Json
    $FuncAppName = ($funcs | Where-Object { $_.tags.'azd-service-name' -eq 'function-docker' } | Select-Object -First 1).name
}

if ([string]::IsNullOrWhiteSpace($FuncAppName)) {
    Write-Host "  WARNING: No Function App with tag azd-service-name='function-docker' found and no SERVICE_FUNCTION_RESOURCE_NAME was available - skipping."
} else {
    Update-FunctionApp -AppName $FuncAppName -ImageName 'rag-backend'
}

Write-Host ""
Write-Host "=============================================="
Write-Host " Build, push, and update complete"
Write-Host "  Registry : https://${AcrLoginServer}"
Write-Host "  Tag      : ${Tag}"
Write-Host "=============================================="
