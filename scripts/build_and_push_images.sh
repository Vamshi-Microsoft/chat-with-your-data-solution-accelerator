#!/bin/bash
set -e

# Prevent Git Bash (MSYS) from mangling Azure resource ID paths like /subscriptions/...
export MSYS_NO_PATHCONV=1

# build_and_push_images.sh
# Builds the three application container images and pushes them to the per-deployment ACR.
# Run this after 'azd provision' / 'azd up' completes and before updating the App Services.
#
# Modes:
#   remote (default)  - Builds inside ACR using 'az acr build'. No local Docker required.
#   local             - Builds with local Docker daemon then pushes. Requires Docker Desktop.
#
# Usage:
#   ./scripts/build_and_push_images.sh [resource-group] [--mode remote|local] [--tag <tag>]
#
# Examples:
#   ./scripts/build_and_push_images.sh rg-cwyd-dev
#   ./scripts/build_and_push_images.sh rg-cwyd-dev --mode local --tag v1.0.0

# -------------------------------------------------------
# Parse arguments
# -------------------------------------------------------
RESOURCE_GROUP=""
BUILD_MODE="remote"
IMAGE_TAG="latest"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            BUILD_MODE="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "$RESOURCE_GROUP" ]; then
                RESOURCE_GROUP="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$RESOURCE_GROUP" ]; then
    read -rp "Enter the resource group name: " RESOURCE_GROUP
    if [ -z "$RESOURCE_GROUP" ]; then
        echo "ERROR: Resource group name is required."
        exit 1
    fi
fi

if [[ "$BUILD_MODE" != "remote" && "$BUILD_MODE" != "local" ]]; then
    echo "ERROR: --mode must be 'remote' or 'local'. Got: '$BUILD_MODE'"
    exit 1
fi

# -------------------------------------------------------
# Resolve repo root (script lives in scripts/)
# -------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -W 2>/dev/null || pwd)"

echo "=============================================="
echo " Build & Push Images"
echo " Resource Group : ${RESOURCE_GROUP}"
echo " Mode           : ${BUILD_MODE}"
echo " Image Tag      : ${IMAGE_TAG}"
echo " Repo Root      : ${REPO_ROOT}"
echo "=============================================="

# -------------------------------------------------------
# Discover ACR in the resource group
# -------------------------------------------------------
echo ""
echo "Discovering Azure Container Registry..."
ACR_NAME=$(az acr list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[0].name" \
    -o tsv 2>/dev/null || true)

if [ -z "$ACR_NAME" ] || [ "$ACR_NAME" == "None" ]; then
    echo "ERROR: No Azure Container Registry found in resource group '$RESOURCE_GROUP'."
    echo "       Make sure 'azd provision' has completed successfully."
    exit 1
fi

ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
echo "  ✓ ACR found: ${ACR_NAME} (${ACR_LOGIN_SERVER})"

# -------------------------------------------------------
# Image → Dockerfile mapping (image-name:dockerfile-path)
# Build context is always the repo root.
# -------------------------------------------------------
IMAGE_NAMES=("rag-webapp"       "rag-adminwebapp"        "rag-backend")
DOCKERFILES=("docker/Frontend.Dockerfile" "docker/Admin.Dockerfile" "docker/Backend.Dockerfile")

# -------------------------------------------------------
# Build and push
# -------------------------------------------------------
echo ""
if [ "$BUILD_MODE" == "local" ]; then
    echo "--- LOCAL BUILD (Docker daemon) ---"

    # Verify Docker is available
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker is not installed or not in PATH."
        echo "       Install Docker Desktop or use '--mode remote' instead."
        exit 1
    fi
    if ! docker info &>/dev/null; then
        echo "ERROR: Docker daemon is not running. Start Docker Desktop and retry."
        exit 1
    fi

    echo "Logging in to ACR '${ACR_NAME}'..."
    az acr login --name "$ACR_NAME"

    for i in "${!IMAGE_NAMES[@]}"; do
        IMAGE="${IMAGE_NAMES[$i]}"
        DOCKERFILE="${DOCKERFILES[$i]}"
        FULL_TAG="${ACR_LOGIN_SERVER}/${IMAGE}:${IMAGE_TAG}"

        echo ""
        echo "[${IMAGE}] Building from ${DOCKERFILE} ..."
        docker build \
            --file "${REPO_ROOT}/${DOCKERFILE}" \
            --tag  "${FULL_TAG}" \
            "${REPO_ROOT}"

        echo "[${IMAGE}] Pushing ${FULL_TAG} ..."
        docker push "${FULL_TAG}"
        echo "[${IMAGE}] ✓ Done"
    done

else
    echo "--- REMOTE BUILD (ACR Tasks — no local Docker required) ---"
    echo "    Note: your Azure identity needs Contributor or AcrPush access on the ACR."
    echo ""

    for i in "${!IMAGE_NAMES[@]}"; do
        IMAGE="${IMAGE_NAMES[$i]}"
        DOCKERFILE="${DOCKERFILES[$i]}"
        FULL_TAG="${IMAGE}:${IMAGE_TAG}"

        echo "[${IMAGE}] Submitting remote build to ACR '${ACR_NAME}' ..."
        az acr build \
            --registry   "$ACR_NAME" \
            --image      "${FULL_TAG}" \
            --file       "${REPO_ROOT}/${DOCKERFILE}" \
            "${REPO_ROOT}"
        echo "[${IMAGE}] ✓ Done"
    done
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "=============================================="
echo " Build & Push Complete"
echo "=============================================="
echo " Images pushed to ${ACR_LOGIN_SERVER}:"
for IMAGE in "${IMAGE_NAMES[@]}"; do
    echo "   ${ACR_LOGIN_SERVER}/${IMAGE}:${IMAGE_TAG}"
done
echo ""
echo " Next step: run update_app_service_images.sh (or .ps1) to point"
echo " the App Services at the new images in ACR."
echo "=============================================="
