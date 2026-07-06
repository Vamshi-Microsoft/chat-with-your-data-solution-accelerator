#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

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
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$RESOURCE_GROUP" ]]; then
                RESOURCE_GROUP="$1"
            else
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac

done

if [[ -z "$RESOURCE_GROUP" ]]; then
    read -rp "Enter the resource group name: " RESOURCE_GROUP
    if [[ -z "$RESOURCE_GROUP" ]]; then
        echo "ERROR: Resource group name is required." >&2
        exit 1
    fi
fi

if [[ "$BUILD_MODE" != "remote" && "$BUILD_MODE" != "local" ]]; then
    echo "ERROR: --mode must be 'remote' or 'local'. Got: '$BUILD_MODE'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/build_and_push_images.sh"
UPDATE_SCRIPT="${SCRIPT_DIR}/update_app_service_images.sh"

if [[ ! -f "$BUILD_SCRIPT" ]]; then
    echo "ERROR: Build script not found: $BUILD_SCRIPT" >&2
    exit 1
fi

if [[ ! -f "$UPDATE_SCRIPT" ]]; then
    echo "ERROR: Update script not found: $UPDATE_SCRIPT" >&2
    exit 1
fi

echo ""
echo "=============================================="
echo " ACR Build, Push & Update"
echo " Resource Group : ${RESOURCE_GROUP}"
echo " Mode           : ${BUILD_MODE}"
echo " Image Tag      : ${IMAGE_TAG}"
echo " Repo Root      : ${REPO_ROOT}"
echo "=============================================="
echo ""

echo "Running image build and push..."
bash "$BUILD_SCRIPT" "$RESOURCE_GROUP" --mode "$BUILD_MODE" --tag "$IMAGE_TAG"

echo ""
echo "Updating App Services and Function App to use the new images..."
bash "$UPDATE_SCRIPT" "$RESOURCE_GROUP" --tag "$IMAGE_TAG"

echo ""
echo "=============================================="
echo " ACR Build, Push & Update complete"
echo "=============================================="
