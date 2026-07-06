#!/usr/bin/env bash
# update_app_service_images.sh
#
# Updates the three CWYD App Services / Function App to use images from the
# per-deployment Azure Container Registry, and configures managed-identity
# based authentication for private-registry pulls.
#
# Prerequisites:
#   • Azure CLI logged in  (az login)
#   • Images already pushed to ACR  (run build_and_push_images.sh first)
#
# Usage:
#   ./scripts/update_app_service_images.sh [<resource-group>] [--tag <tag>]
#
# Options:
#   <resource-group>   Azure resource group name (prompted if omitted)
#   --tag  <tag>       Image tag to deploy (default: latest)

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
RESOURCE_GROUP=""
TAG="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag|-t)
      TAG="$2"; shift 2 ;;
    -*)
      echo "Unknown flag: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$RESOURCE_GROUP" ]]; then
        RESOURCE_GROUP="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; exit 1
      fi ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then
  read -rp "Enter resource group name: " RESOURCE_GROUP
fi

echo ""
echo "============================================================"
echo " CWYD – Update App Service container images"
echo "  Resource group : $RESOURCE_GROUP"
echo "  Image tag      : $TAG"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Discover shared resources
# ---------------------------------------------------------------------------
echo "Discovering resources in resource group '$RESOURCE_GROUP'..."

ACR_NAME=$(az acr list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].name" \
  --output tsv 2>/dev/null || true)

if [[ -z "$ACR_NAME" ]]; then
  echo "ERROR: No Azure Container Registry found in resource group '$RESOURCE_GROUP'." >&2
  echo "       Run 'azd provision' to create infrastructure first." >&2
  exit 1
fi

ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"

MI_CLIENT_ID=$(az identity list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].clientId" \
  --output tsv 2>/dev/null || true)

if [[ -z "$MI_CLIENT_ID" ]]; then
  echo "ERROR: No user-assigned managed identity found in resource group '$RESOURCE_GROUP'." >&2
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id --output tsv)

echo "  ACR             : $ACR_LOGIN_SERVER"
echo "  Managed identity: $MI_CLIENT_ID"
echo ""

# ---------------------------------------------------------------------------
# Helper: update a web app
# ---------------------------------------------------------------------------
update_webapp() {
  local APP_NAME="$1"
  local IMAGE_NAME="$2"
  local FULL_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${TAG}"

  echo "  Updating App Service: $APP_NAME"
  echo "    Image: $FULL_IMAGE"

  # 1. Set container image and registry URL via config
  az webapp config container set \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --container-image-name "$FULL_IMAGE" \
    --output none

  # 2. Set DOCKER_REGISTRY_SERVER_URL app setting
  az webapp config appsettings set \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --settings "DOCKER_REGISTRY_SERVER_URL=https://${ACR_LOGIN_SERVER}" \
    --output none

  # 3. Enable ACR pull with user-assigned managed identity
  az resource update \
    --ids "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${APP_NAME}" \
    --set "properties.siteConfig.acrUseManagedIdentityCreds=true" \
    --set "properties.siteConfig.acrUserManagedIdentityID=${MI_CLIENT_ID}" \
    --output none

  # 4. Restart to apply changes
  az webapp restart \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP"

  echo "    Done."
}

# ---------------------------------------------------------------------------
# Helper: update a function app
# ---------------------------------------------------------------------------
update_functionapp() {
  local APP_NAME="$1"
  local IMAGE_NAME="$2"
  local FULL_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${TAG}"

  echo "  Updating Function App: $APP_NAME"
  echo "    Image: $FULL_IMAGE"

  # 1. Set DOCKER_REGISTRY_SERVER_URL app setting
  az functionapp config appsettings set \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --settings "DOCKER_REGISTRY_SERVER_URL=https://${ACR_LOGIN_SERVER}" \
    --output none

  # 2. Set the Linux custom container image and managed identity pull
  az resource update \
    --ids "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${APP_NAME}" \
    --set "properties.siteConfig.linuxFxVersion=DOCKER|${FULL_IMAGE}" \
    --set "properties.siteConfig.acrUseManagedIdentityCreds=true" \
    --set "properties.siteConfig.acrUserManagedIdentityID=${MI_CLIENT_ID}" \
    --output none

  # 3. Restart
  az functionapp restart \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP"

  echo "    Done."
}

# ---------------------------------------------------------------------------
# Discover and update each service
# ---------------------------------------------------------------------------

# Mapping: azd-service-name tag -> Docker image name
declare -A SERVICE_IMAGES=(
  ["web-docker"]="rag-webapp"
  ["adminweb-docker"]="rag-adminwebapp"
)

# -- Web apps ---
echo "Updating web App Services..."
for SERVICE_TAG in "web-docker" "adminweb-docker"; do
  APP_NAME=$(az webapp list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?tags.\"azd-service-name\"=='${SERVICE_TAG}'].name | [0]" \
    --output tsv 2>/dev/null || true)

  if [[ -z "$APP_NAME" ]]; then
    echo "  WARNING: No App Service with tag azd-service-name='${SERVICE_TAG}' found – skipping."
    continue
  fi

  update_webapp "$APP_NAME" "${SERVICE_IMAGES[$SERVICE_TAG]}"
done

# -- Function App ---
echo ""
echo "Updating Function App..."
FUNC_APP_NAME=$(az functionapp list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?tags.\"azd-service-name\"=='function-docker'].name | [0]" \
  --output tsv 2>/dev/null || true)

if [[ -z "$FUNC_APP_NAME" ]]; then
  echo "  WARNING: No Function App with tag azd-service-name='function-docker' found – skipping."
else
  update_functionapp "$FUNC_APP_NAME" "rag-backend"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Update complete!"
echo "  Registry : https://${ACR_LOGIN_SERVER}"
echo "  Tag      : ${TAG}"
echo ""
echo " Apps are restarting and will pull images from ACR."
echo " Monitor health via Azure Portal or:"
echo "   az webapp log tail --name <app-name> --resource-group $RESOURCE_GROUP"
echo "============================================================"
