<#
.SYNOPSIS
    Builds the application container images, pushes them to the per-deployment ACR,
    and updates the App Services / Function App.
.DESCRIPTION
    This script is a thin wrapper around the existing build_and_push_images.ps1 and
    update_app_service_images.ps1 scripts so it behaves like the combined workflow.
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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$BuildScript = Join-Path $ScriptDir 'build_and_push_images.ps1'
$UpdateScript = Join-Path $ScriptDir 'update_app_service_images.ps1'

if (-not (Test-Path $BuildScript)) {
    throw "Build script not found: $BuildScript"
}

if (-not (Test-Path $UpdateScript)) {
    throw "Update script not found: $UpdateScript"
}

Write-Host "=============================================="
Write-Host " ACR Build, Push & Update"
Write-Host " Resource Group : $ResourceGroupName"
Write-Host " Mode           : $Mode"
Write-Host " Image Tag      : $Tag"
Write-Host " Repo Root      : $RepoRoot"
Write-Host "=============================================="
Write-Host ""

Write-Host "Running image build and push..."
& $BuildScript -ResourceGroupName $ResourceGroupName -Mode $Mode -Tag $Tag
if ($LASTEXITCODE -ne 0) {
    throw "build_and_push_images.ps1 failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Updating App Services and Function App to use the new images..."
& $UpdateScript -ResourceGroupName $ResourceGroupName -Tag $Tag
if ($LASTEXITCODE -ne 0) {
    throw "update_app_service_images.ps1 failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "=============================================="
Write-Host " ACR Build, Push & Update complete"
Write-Host "=============================================="
