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

ACR_NAME=""
ACR_LOGIN_SERVER=""
SERVICE_WEB_RESOURCE_NAME=""
SERVICE_ADMINWEB_RESOURCE_NAME=""
SERVICE_FUNCTION_RESOURCE_NAME=""
MI_CLIENT_ID=""

load_azure_env_values() {
    local azure_dir="${REPO_ROOT}/.azure"
    if [[ ! -d "$azure_dir" ]]; then
        return
    fi

    local env_file
    while IFS= read -r env_file; do
        if [[ -z "$env_file" ]]; then
            continue
        fi

        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*"?(.*)"?[[:space:]]*$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                case "$key" in
                    ACR_NAME)
                        ACR_NAME="$value"
                        ;;
                    ACR_LOGIN_SERVER)
                        ACR_LOGIN_SERVER="$value"
                        ;;
                    SERVICE_WEB_RESOURCE_NAME)
                        SERVICE_WEB_RESOURCE_NAME="$value"
                        ;;
                    SERVICE_ADMINWEB_RESOURCE_NAME)
                        SERVICE_ADMINWEB_RESOURCE_NAME="$value"
                        ;;
                    SERVICE_FUNCTION_RESOURCE_NAME)
                        SERVICE_FUNCTION_RESOURCE_NAME="$value"
                        ;;
                esac
            fi
        done <"$env_file"

        if [[ -n "$ACR_NAME" || -n "$ACR_LOGIN_SERVER" ]]; then
            echo "Loaded environment values from ${env_file}"
            [[ -n "$ACR_NAME" ]] && echo "  ACR_NAME=$ACR_NAME"
            [[ -n "$ACR_LOGIN_SERVER" ]] && echo "  ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER"
            [[ -n "$SERVICE_WEB_RESOURCE_NAME" ]] && echo "  SERVICE_WEB_RESOURCE_NAME=$SERVICE_WEB_RESOURCE_NAME"
            [[ -n "$SERVICE_ADMINWEB_RESOURCE_NAME" ]] && echo "  SERVICE_ADMINWEB_RESOURCE_NAME=$SERVICE_ADMINWEB_RESOURCE_NAME"
            [[ -n "$SERVICE_FUNCTION_RESOURCE_NAME" ]] && echo "  SERVICE_FUNCTION_RESOURCE_NAME=$SERVICE_FUNCTION_RESOURCE_NAME"
            return
        fi
    done < <(find "$azure_dir" -type f -name '.env' 2>/dev/null)
}

get_deployment_outputs() {
    local deployment_name
    deployment_name=$(az deployment group list --resource-group "$RESOURCE_GROUP" --query '[0].name' -o tsv 2>/dev/null || true)
    if [[ -n "$deployment_name" ]]; then
        local output_value

        output_value=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$deployment_name" --query 'properties.outputs.ACR_NAME.value' -o tsv 2>/dev/null || true)
        if [[ -n "$output_value" && "$output_value" != "None" ]]; then
            ACR_NAME="$output_value"
        fi

        output_value=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$deployment_name" --query 'properties.outputs.ACR_LOGIN_SERVER.value' -o tsv 2>/dev/null || true)
        if [[ -n "$output_value" && "$output_value" != "None" ]]; then
            ACR_LOGIN_SERVER="$output_value"
        fi

        output_value=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$deployment_name" --query 'properties.outputs.MANAGED_IDENTITY_CLIENT_ID.value' -o tsv 2>/dev/null || true)
        if [[ -n "$output_value" && "$output_value" != "None" ]]; then
            MI_CLIENT_ID="$output_value"
        fi

        output_value=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$deployment_name" --query 'properties.outputs.SERVICE_WEB_RESOURCE_NAME.value' -o tsv 2>/dev/null || true)
        if [[ -n "$output_value" && "$output_value" != "None" ]]; then
            SERVICE_WEB_RESOURCE_NAME="$output_value"
        fi

        output_value=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$deployment_name" --query 'properties.outputs.SERVICE_ADMINWEB_RESOURCE_NAME.value' -o tsv 2>/dev/null || true)
        if [[ -n "$output_value" && "$output_value" != "None" ]]; then
            SERVICE_ADMINWEB_RESOURCE_NAME="$output_value"
        fi

        output_value=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$deployment_name" --query 'properties.outputs.SERVICE_FUNCTION_RESOURCE_NAME.value' -o tsv 2>/dev/null || true)
        if [[ -n "$output_value" && "$output_value" != "None" ]]; then
            SERVICE_FUNCTION_RESOURCE_NAME="$output_value"
        fi
    fi
}

load_azure_env_values
get_deployment_outputs

if [[ -z "$ACR_NAME" && -n "$ACR_LOGIN_SERVER" ]]; then
    if [[ "$ACR_LOGIN_SERVER" =~ ^(.+)\.azurecr\.io$ ]]; then
        ACR_NAME="${BASH_REMATCH[1]}"
    fi
fi

if [[ -z "$ACR_NAME" ]]; then
    echo ""
    echo "Discovering Azure Container Registry..."
    ACR_NAME=$(az acr list --resource-group "$RESOURCE_GROUP" --query '[0].name' -o tsv 2>/dev/null || true)
fi

if [[ -z "$ACR_NAME" || "$ACR_NAME" == "None" ]]; then
    echo "ERROR: No Azure Container Registry found in resource group '$RESOURCE_GROUP'." >&2
    echo "       Make sure 'azd provision' has completed successfully." >&2
    exit 1
fi

if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
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
echo "  ACR found: ${ACR_NAME} (${ACR_LOGIN_SERVER})"

declare -a IMAGE_NAMES=("rag-webapp" "rag-adminwebapp" "rag-backend")
declare -a DOCKERFILES=("docker/Frontend.Dockerfile" "docker/Admin.Dockerfile" "docker/Backend.Dockerfile")

echo ""
if [[ "$BUILD_MODE" == "local" ]]; then
    echo "--- LOCAL BUILD (Docker daemon) ---"

    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker is not installed or not in PATH." >&2
        echo "       Install Docker Desktop or use '--mode remote' instead." >&2
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "ERROR: Docker daemon is not running. Start Docker Desktop and retry." >&2
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
        docker build --file "${REPO_ROOT}/${DOCKERFILE}" --tag "${FULL_TAG}" "${REPO_ROOT}"

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
        az acr build --registry "$ACR_NAME" --image "$FULL_TAG" --file "${REPO_ROOT}/${DOCKERFILE}" "${REPO_ROOT}"
        echo "[${IMAGE}] ✓ Done"
    done
fi

echo ""
if [[ -z "$MI_CLIENT_ID" ]]; then
    MI_CLIENT_ID=$(az identity list --resource-group "$RESOURCE_GROUP" --query '[0].clientId' -o tsv 2>/dev/null || true)
fi

if [[ -z "$MI_CLIENT_ID" || "$MI_CLIENT_ID" == "None" ]]; then
    echo "ERROR: No user-assigned managed identity found in resource group '$RESOURCE_GROUP'." >&2
    exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

update_webapp() {
    local APP_NAME="$1"
    local IMAGE_NAME="$2"
    local FULL_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

    echo "  Updating App Service: ${APP_NAME}"
    echo "    Image: ${FULL_IMAGE}"

    az webapp config container set --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --container-image-name "$FULL_IMAGE" --output none
    az webapp config appsettings set --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --settings "DOCKER_REGISTRY_SERVER_URL=https://${ACR_LOGIN_SERVER}" --output none
    az resource update --ids "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${APP_NAME}" --set "properties.siteConfig.acrUseManagedIdentityCreds=true" --set "properties.siteConfig.acrUserManagedIdentityID=${MI_CLIENT_ID}" --output none
    az webapp restart --name "$APP_NAME" --resource-group "$RESOURCE_GROUP"
    echo "    Done."
}

update_functionapp() {
    local APP_NAME="$1"
    local IMAGE_NAME="$2"
    local FULL_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

    echo "  Updating Function App: ${APP_NAME}"
    echo "    Image: ${FULL_IMAGE}"

    az functionapp config appsettings set --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --settings "DOCKER_REGISTRY_SERVER_URL=https://${ACR_LOGIN_SERVER}" --output none
    az resource update --ids "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${APP_NAME}" --set "properties.siteConfig.linuxFxVersion=DOCKER|${FULL_IMAGE}" --set "properties.siteConfig.acrUseManagedIdentityCreds=true" --set "properties.siteConfig.acrUserManagedIdentityID=${MI_CLIENT_ID}" --output none
    az functionapp restart --name "$APP_NAME" --resource-group "$RESOURCE_GROUP"
    echo "    Done."
}

echo ""
echo "Updating web App Services..."
for SERVICE_TAG in "web-docker" "adminweb-docker"; do
    if [[ "$SERVICE_TAG" == "web-docker" ]]; then
        APP_NAME="$SERVICE_WEB_RESOURCE_NAME"
    else
        APP_NAME="$SERVICE_ADMINWEB_RESOURCE_NAME"
    fi

    if [[ -z "$APP_NAME" ]]; then
        APP_NAME=$(az webapp list --resource-group "$RESOURCE_GROUP" --query "[?tags.'azd-service-name'=='${SERVICE_TAG}'].name | [0]" -o tsv 2>/dev/null || true)
    fi

    if [[ -z "$APP_NAME" ]]; then
        echo "  WARNING: No App Service with tag azd-service-name='${SERVICE_TAG}' found - skipping."
        continue
    fi

    if [[ "$SERVICE_TAG" == "web-docker" ]]; then
        update_webapp "$APP_NAME" "rag-webapp"
    else
        update_webapp "$APP_NAME" "rag-adminwebapp"
    fi

done

echo ""
echo "Updating Function App..."
if [[ -n "$SERVICE_FUNCTION_RESOURCE_NAME" ]]; then
    echo "  Using environment-provided Function App name: $SERVICE_FUNCTION_RESOURCE_NAME"
    FUNC_APP_NAME="$SERVICE_FUNCTION_RESOURCE_NAME"
else
    FUNC_APP_NAME=$(az functionapp list --resource-group "$RESOURCE_GROUP" --query "[?tags.'azd-service-name'=='function-docker'].name | [0]" -o tsv 2>/dev/null || true)
fi

if [[ -z "$FUNC_APP_NAME" ]]; then
    echo "  WARNING: No Function App with tag azd-service-name='function-docker' found and no SERVICE_FUNCTION_RESOURCE_NAME was available - skipping."
else
    update_functionapp "$FUNC_APP_NAME" "rag-backend"
fi

echo ""
echo "=============================================="
echo " Build, push, and update complete"
echo "  Registry : https://${ACR_LOGIN_SERVER}"
echo "  Tag      : ${IMAGE_TAG}"
echo "=============================================="
