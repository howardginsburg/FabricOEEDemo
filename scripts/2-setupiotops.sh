#!/usr/bin/env bash
# =============================================================================
# 2-setupiotops.sh — Deploy OEE MQTT connector device and dataflow to AIO
#
# Creates: A Device with MQTT inbound endpoint (the connector auto-discovers
#          topics and creates DiscoveredAssets), and an optional dataflow to
#          Microsoft Fabric Real-Time Intelligence — all via the az iot ops CLI.
#
# After running this script, promote (import) the discovered assets in the
# Operations Experience portal to enable forwarding to the unified namespace.
#
# Prerequisites:
#   - Azure CLI 2.67.0+ with the azure-iot-ops extension
#   - Azure IoT Operations deployed (see IoT Operations Quickstart)
#   - For the dataflow: Fabric Eventstream with a custom endpoint source,
#     published and with Entra ID authentication available.
#
# Usage:
#   bash 2-setupiotops.sh --instance <name> --resource-group <rg>
#   bash 2-setupiotops.sh --instance <name> --resource-group <rg> \
#     --workspace-name <fabric-workspace> \
#     --eventhub-namespace <host> --eventhub-name <es_xxx>
#
# Without --workspace-name, only the device is created (no dataflow).
# You can add the dataflow later via the Operations Experience UI.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Fixed defaults (not user-configurable) ─────────────────────────────────────
DEVICE_NAME="oee-mqtt-device"
ENDPOINT_NAME="oee-mqtt-endpoint"
BROKER_ADDRESS="mqtt://aio-broker-loadbalancer.azure-iot-operations.svc.cluster.local:1883"
TOPIC_FILTER="oee/+/+"
ASSET_LEVEL=3
TOPIC_MAPPING_PREFIX="unified"

# ── User-configurable (via CLI args) ──────────────────────────────────────────
INSTANCE=""
RESOURCE_GROUP=""
WORKSPACE_NAME=""
EVENTHUB_NAMESPACE=""
EVENTHUB_NAME=""

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi
ok()   { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "   ${RED}✗ ERROR:${RESET} %s\n" "$*" >&2; exit 1; }
step() { printf "\n── %s\n" "$*"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)        INSTANCE="$2";       shift 2 ;;
    --resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
    --workspace-name)      WORKSPACE_NAME="$2";      shift 2 ;;
    --eventhub-namespace)  EVENTHUB_NAMESPACE="$2";  shift 2 ;;
    --eventhub-name)       EVENTHUB_NAME="$2";       shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE" ]]       || die "Missing required argument: --instance <AIO instance name>"
[[ -n "$RESOURCE_GROUP" ]] || die "Missing required argument: --resource-group <resource group>"

echo "================================================="
echo "OEE Simulator — Deploy Assets to Azure IoT Operations"
echo "================================================="
echo "Instance:      $INSTANCE"
echo "Resource Group: $RESOURCE_GROUP"
echo "Device:        $DEVICE_NAME"
echo "Endpoint:      $ENDPOINT_NAME"
echo "Topic filter:  $TOPIC_FILTER"
if [[ -n "$WORKSPACE_NAME" ]]; then
  echo "Fabric:        workspace '$WORKSPACE_NAME' (Entra ID auth)"
  echo "EH Namespace:  $EVENTHUB_NAMESPACE"
  echo "EH Name:       $EVENTHUB_NAME"
else
  echo "Fabric:        (skipped — no --workspace-name provided)"
fi
echo "================================================="

# ── Verify az iot ops extension ───────────────────────────────────────────────
step "Verifying Azure CLI and IoT Operations extension"
az extension show --name azure-iot-ops > /dev/null 2>&1 || die "azure-iot-ops extension not installed. Run: az extension add --name azure-iot-ops"
ok "azure-iot-ops extension is installed"

# ── Create Device ─────────────────────────────────────────────────────────────
step "Creating device: $DEVICE_NAME"

az iot ops ns device create \
  --name "$DEVICE_NAME" \
  --instance "$INSTANCE" \
  -g "$RESOURCE_GROUP" \
  --output none 2>/dev/null || true
ok "Device '$DEVICE_NAME' ready"

# ── Add MQTT inbound endpoint to device ───────────────────────────────────────
step "Adding MQTT inbound endpoint: $ENDPOINT_NAME"

az iot ops ns device endpoint inbound add custom \
  --device "$DEVICE_NAME" \
  --instance "$INSTANCE" \
  -g "$RESOURCE_GROUP" \
  --name "$ENDPOINT_NAME" \
  --endpoint-type "Microsoft.Mqtt" \
  --endpoint-address "$BROKER_ADDRESS" \
  --additional-config '{"topicFilter":"'"$TOPIC_FILTER"'","assetLevel":'"$ASSET_LEVEL"',"topicMappingPrefix":"'"$TOPIC_MAPPING_PREFIX"'"}' \
  --version 5 \
  --replace \
  --output none
ok "MQTT endpoint '$ENDPOINT_NAME' added (topic filter: $TOPIC_FILTER, asset level: $ASSET_LEVEL)"

# ── Asset discovery & promotion ──────────────────────────────────────────────
# The MQTT connector automatically discovers topics matching the topic filter
# and creates DiscoveredAsset resources. After discovery, we promote them to
# managed Assets so the connector forwards messages to the unified namespace.
step "Asset discovery & promotion"
ok "The MQTT connector will auto-discover topics matching '$TOPIC_FILTER'"
warn "Waiting 90 seconds for the connector to discover topics..."
sleep 90

# Promote discovered assets using the companion script
PROMOTE_SCRIPT="${SCRIPT_DIR}/3-setup-iotops-assets.sh"
if [[ -f "$PROMOTE_SCRIPT" ]]; then
  bash "$PROMOTE_SCRIPT" --instance "$INSTANCE" --resource-group "$RESOURCE_GROUP"
else
  warn "3-setup-iotops-assets.sh not found — promote assets manually in https://iotoperations.azure.com"
fi

# ── Dataflow via Entra ID (optional) ─────────────────────────────────────────
if [[ -n "$WORKSPACE_NAME" ]]; then

  [[ -n "$EVENTHUB_NAMESPACE" ]]  || die "--eventhub-namespace required when --workspace-name is set (e.g. xxxx.servicebus.windows.net:9093)"
  [[ -n "$EVENTHUB_NAME" ]] || die "--eventhub-name required when --workspace-name is set (e.g. es_aaaaaaaa-...)"

  # Fabric portal omits the port — append :9093 if missing
  if [[ "$EVENTHUB_NAMESPACE" != *:* ]]; then
    EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE}:9093"
    warn "No port in --eventhub-namespace; using ${EVENTHUB_NAMESPACE}"
  fi

  FABRIC_API="https://api.fabric.microsoft.com/v1"
  FABRIC_RESOURCE="https://api.fabric.microsoft.com"

  # ── Helpers ──────────────────────────────────────────────────────────────────
  fabric_get() {
    az rest --method GET --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" --output json
  }
  fabric_post() {
    local tmp
    tmp=$(mktemp)
    printf '%s' "$2" > "$tmp"
    az rest --method POST \
      --uri "${FABRIC_API}/$1" \
      --resource "$FABRIC_RESOURCE" \
      --headers "Content-Type=application/json" \
      --body "@${tmp}" \
      --output none
    rm -f "$tmp"
  }

  # ── Find workspace ──────────────────────────────────────────────────────────
  step "Looking up Fabric workspace: $WORKSPACE_NAME"
  WS_LIST=$(fabric_get "workspaces") || die "Failed to list workspaces — check 'az login' and Fabric permissions."
  WS_ID=$(echo "$WS_LIST" | jq -r --arg n "$WORKSPACE_NAME" \
    '.value[] | select(.displayName == $n) | .id' | head -1 || true)
  [[ -n "$WS_ID" ]] || die "Workspace '$WORKSPACE_NAME' not found."
  ok "Workspace: $WORKSPACE_NAME ($WS_ID)"

  # ── Find AIO extension managed identity ─────────────────────────────────────
  step "Finding AIO Arc extension managed identity"

  # Get the connected cluster name from the AIO instance
  AIO_DETAIL=$(az iot ops show --name "$INSTANCE" -g "$RESOURCE_GROUP" --output json 2>/dev/null) \
    || die "Failed to retrieve AIO instance details."
  CLUSTER_RESOURCE_ID=$(echo "$AIO_DETAIL" | jq -r '.extendedLocation.name // empty')
  [[ -n "$CLUSTER_RESOURCE_ID" ]] || die "Could not determine the cluster resource ID from AIO instance."

  # Extract cluster name and resource group from the custom location
  CUSTOM_LOC=$(az rest --method GET \
    --uri "${CLUSTER_RESOURCE_ID}?api-version=2021-08-15" \
    --output json 2>/dev/null) || die "Failed to get custom location details."
  HOST_RESOURCE_ID=$(echo "$CUSTOM_LOC" | jq -r '.properties.hostResourceId // empty')
  [[ -n "$HOST_RESOURCE_ID" ]] || die "Could not determine host cluster from custom location."

  ARC_CLUSTER_NAME=$(echo "$HOST_RESOURCE_ID" | sed -n 's|.*/connectedClusters/\(.*\)|\1|p')
  ARC_CLUSTER_RG=$(echo "$HOST_RESOURCE_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')
  ok "Arc cluster: $ARC_CLUSTER_NAME (rg: $ARC_CLUSTER_RG)"

  # Get the AIO extension's managed identity principal ID
  AIO_EXT=$(az k8s-extension list \
    --cluster-name "$ARC_CLUSTER_NAME" \
    --cluster-type connectedClusters \
    -g "$ARC_CLUSTER_RG" \
    --output json 2>/dev/null) || die "Failed to list k8s extensions."

  AIO_MI_PRINCIPAL=$(echo "$AIO_EXT" | jq -r \
    '.[] | select(.extensionType == "microsoft.iotoperations") | .identity.principalId // empty' | head -1)
  AIO_EXT_NAME=$(echo "$AIO_EXT" | jq -r \
    '.[] | select(.extensionType == "microsoft.iotoperations") | .name // empty' | head -1)
  [[ -n "$AIO_MI_PRINCIPAL" ]] || die "Could not find managed identity for the AIO extension."
  ok "AIO extension: $AIO_EXT_NAME (principal: $AIO_MI_PRINCIPAL)"

  # ── Grant Contributor on Fabric workspace ───────────────────────────────────
  step "Granting AIO managed identity Contributor access on Fabric workspace"

  # Check if already has access, then add if not
  EXISTING_ROLE=$(az rest --method GET \
    --uri "${FABRIC_API}/workspaces/$WS_ID/roleAssignments" \
    --resource "$FABRIC_RESOURCE" \
    --output json 2>/dev/null \
    | jq -r --arg pid "$AIO_MI_PRINCIPAL" \
      '.value[]? | select(.principal.id == $pid) | .role // empty' 2>/dev/null | head -1 || true)

  if [[ -n "$EXISTING_ROLE" ]]; then
    ok "AIO extension already has '$EXISTING_ROLE' access on the workspace"
  else
    ROLE_BODY=$(jq -n --arg pid "$AIO_MI_PRINCIPAL" \
      '{principal:{id:$pid,type:"ServicePrincipal"},role:"Contributor"}')
    fabric_post "workspaces/$WS_ID/roleAssignments" "$ROLE_BODY" \
      || die "Failed to grant Contributor role on workspace."
    ok "Granted Contributor role to AIO extension on workspace '$WORKSPACE_NAME'"
  fi

  # ── Create dataflow endpoint with managed identity auth ─────────────────────
  step "Creating Fabric Real-Time Intelligence dataflow endpoint"

  az iot ops dataflow endpoint create fabric-realtime \
    --name oee-fabric-rti-endpoint \
    --instance "$INSTANCE" \
    -g "$RESOURCE_GROUP" \
    --host "$EVENTHUB_NAMESPACE" \
    --auth-type SystemAssignedManagedIdentity \
    --output none 2>/dev/null || true
  ok "Dataflow endpoint 'fabric-rti-endpoint' created (Entra ID auth)"

  # ── Create dataflow ─────────────────────────────────────────────────────────
  step "Creating dataflow: unified/oee/# + oee/+/parts + oee/+/maintenance → Fabric"

  DATAFLOW_CONFIG=$(mktemp)
  cat > "$DATAFLOW_CONFIG" <<DFJSON
{
  "mode": "Enabled",
  "operations": [
    {
      "operationType": "Source",
      "sourceSettings": {
        "endpointRef": "default",
        "dataSources": ["unified/oee/#", "oee/+/parts", "oee/+/maintenance"]
      }
    },
    {
      "operationType": "BuiltInTransformation",
      "builtInTransformationSettings": {
        "serializationFormat": "Json",
        "map": [
          { "type": "PassThrough", "inputs": ["*"], "output": "*" }
        ]
      }
    },
    {
      "operationType": "Destination",
      "destinationSettings": {
        "endpointRef": "oee-fabric-rti-endpoint",
        "dataDestination": "$EVENTHUB_NAME"
      }
    }
  ]
}
DFJSON

  az iot ops dataflow apply \
    --name oee-to-fabric \
    --instance "$INSTANCE" \
    -g "$RESOURCE_GROUP" \
    --profile default \
    --config-file "$DATAFLOW_CONFIG" \
    --output none
  rm -f "$DATAFLOW_CONFIG"
  ok "Dataflow 'oee-to-fabric' created"

else
  warn "Skipping dataflow — use --workspace-name to create it with Entra ID auth"
  warn "Or create the dataflow manually in the Operations Experience UI"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
step "Done"
ok "Device:   $DEVICE_NAME (endpoint: $ENDPOINT_NAME)"
ok "Assets:   auto-discovered via MQTT connector (topic filter: $TOPIC_FILTER)"
if [[ -n "$WORKSPACE_NAME" ]]; then
  ok "Dataflow: oee-to-fabric → Fabric workspace '$WORKSPACE_NAME' (Entra ID)"
fi
echo ""
echo "Next steps:"
echo "  1. Run the simulator with topic 'oee/{lineId}/{deviceId}'"
echo "  2. Verify unified namespace: subscribe to unified/oee/# on the broker"
echo "  3. Follow the main tutorial for Eventhouse + Dashboard setup"
