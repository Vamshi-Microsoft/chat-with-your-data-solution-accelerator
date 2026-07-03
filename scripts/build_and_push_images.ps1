<#
.SYNOPSIS
    Builds the three application container images and pushes them to the per-deployment ACR.
    Run this after 'azd provision' / 'azd up' completes and before updating the App Services.
.DESCRIPTION
    Modes:
      remote (default) - Builds inside ACR using 'az acr build'. No local Docker required.
      local            - Builds with local Docker daemon then pushes. Requires Docker Desktop.
.PARAMETER ResourceGroupName
    The name of the Azure resource group containing the deployed resources.
.PARAMETER Mode
    Build mode: 'remote' (default) or 'local'.
.PARAMETER Tag
    Image tag to apply. Defaults to 'latest'.
.EXAMPLE
    ./scripts/build_and_push_images.ps1 -ResourceGroupName "rg-cwyd-dev"
.EXAMPLE
    ./scripts/build_and_push_images.ps1 -ResourceGroupName "rg-cwyd-dev" -Mode local -Tag v1.0.0
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

# -------------------------------------------------------
# Resolve repo root (script lives in scripts/)
# -------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir

Write-Host "=============================================="
Write-Host " Build & Push Images"
Write-Host " Resource Group : $ResourceGroupName"
Write-Host " Mode           : $Mode"
Write-Host " Image Tag      : $Tag"
Write-Host " Repo Root      : $RepoRoot"
Write-Host "=============================================="

# -------------------------------------------------------
# Discover ACR in the resource group
# -------------------------------------------------------
Write-Host ""
Write-Host "Discovering Azure Container Registry..."

$AcrName = az acr list `
    --resource-group $ResourceGroupName `
    --query "[0].name" `
    -o tsv 2>$null

if (-not $AcrName -or $AcrName -eq "None") {
    Write-Error "No Azure Container Registry found in resource group '$ResourceGroupName'.`nMake sure 'azd provision' has completed successfully."
    exit 1
}

$AcrLoginServer = "${AcrName}.azurecr.io"
Write-Host "  OK ACR found: $AcrName ($AcrLoginServer)"

# -------------------------------------------------------
# Image -> Dockerfile mapping
# Build context is always the repo root.
# -------------------------------------------------------
$Images = @(
    @{ Name = "rag-webapp";      Dockerfile = "docker\Frontend.Dockerfile" },
    @{ Name = "rag-adminwebapp"; Dockerfile = "docker\Admin.Dockerfile"    },
    @{ Name = "rag-backend";     Dockerfile = "docker\Backend.Dockerfile"  }
)

# -------------------------------------------------------
# Build and push
# -------------------------------------------------------
Write-Host ""

if ($Mode -eq "local") {
    Write-Host "--- LOCAL BUILD (Docker daemon) ---"

    # Verify Docker is available
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error "Docker is not installed or not in PATH.`nInstall Docker Desktop or use '-Mode remote' instead."
        exit 1
    }

    $dockerInfo = docker info 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker daemon is not running. Start Docker Desktop and retry."
        exit 1
    }

    Write-Host "Logging in to ACR '$AcrName'..."
    az acr login --name $AcrName
    if ($LASTEXITCODE -ne 0) { Write-Error "ACR login failed."; exit 1 }

    foreach ($img in $Images) {
        $FullTag     = "${AcrLoginServer}/$($img.Name):${Tag}"
        $Dockerfile  = Join-Path $RepoRoot $img.Dockerfile

        Write-Host ""
        Write-Host "[$($img.Name)] Building from $($img.Dockerfile) ..."
        docker build `
            --file  $Dockerfile `
            --tag   $FullTag `
            $RepoRoot
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
        $FullTag    = "$($img.Name):${Tag}"
        $Dockerfile = Join-Path $RepoRoot $img.Dockerfile

        Write-Host "[$($img.Name)] Submitting remote build to ACR '$AcrName' ..."
        az acr build `
            --registry  $AcrName `
            --image     $FullTag `
            --file      $Dockerfile `
            $RepoRoot
        if ($LASTEXITCODE -ne 0) { Write-Error "Remote build failed for $($img.Name)."; exit 1 }

        Write-Host "[$($img.Name)] OK Done"
    }
}

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
Write-Host ""
Write-Host "=============================================="
Write-Host " Build & Push Complete"
Write-Host "=============================================="
Write-Host " Images pushed to ${AcrLoginServer}:"
foreach ($img in $Images) {
    Write-Host "   ${AcrLoginServer}/$($img.Name):${Tag}"
}
Write-Host ""
Write-Host " Next step: run update_app_service_images.ps1 (or .sh) to point"
Write-Host " the App Services at the new images in ACR."
Write-Host "=============================================="
