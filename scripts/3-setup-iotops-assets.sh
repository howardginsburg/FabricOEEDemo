#!/usr/bin/env bash
# =============================================================================
# 3-setup-iotops-assets.sh — Bulk-promote discovered assets to Assets
#
# Reads DiscoveredAssets via the ARM REST API and creates corresponding Asset
# resources. This is the scripted equivalent of clicking "Import" for each
# discovered asset in the Operations Experience portal.
#
# No kubectl or cluster access needed — just az login.
#
# Prerequisites:
#   - Azure CLI 2.67.0+ with the azure-iot-ops extension
#   - jq installed
#   - Discovered assets already exist (run the simulator + MQTT connector first)
#
# Usage:
#   bash 3-setup-iotops-assets.sh \
#     --instance <aio-instance> --resource-group <rg>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTANCE=""
RESOURCE_GROUP=""
API_VERSION="2025-10-01"

# OEE asset filter: matches only station discovered assets
FILTER_PATTERN="^line-.*-station-"

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
    --instance)        INSTANCE="$2";        shift 2 ;;
    --resource-group)  RESOURCE_GROUP="$2";  shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE" ]]       || die "Missing required: --instance <AIO instance name>"
[[ -n "$RESOURCE_GROUP" ]] || die "Missing required: --resource-group <resource group>"

echo "================================================="
echo "Promote Discovered Assets to Managed Assets"
echo "================================================="
echo "Instance:       $INSTANCE"
echo "Resource Group: $RESOURCE_GROUP"
echo "================================================="

# ── Verify prerequisites ─────────────────────────────────────────────────────
step "Checking prerequisites"
command -v az >/dev/null 2>&1 || die "az CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
az extension show --name azure-iot-ops > /dev/null 2>&1 || die "azure-iot-ops extension not installed"
ok "az, jq, azure-iot-ops extension available"

# ── Resolve AIO instance details ─────────────────────────────────────────────
step "Resolving AIO instance details"

AIO_DETAIL=$(az iot ops show --name "$INSTANCE" -g "$RESOURCE_GROUP" --output json 2>/dev/null) \
  || die "Failed to retrieve AIO instance '$INSTANCE'. Check name, resource group, and az login."

CUSTOM_LOCATION=$(echo "$AIO_DETAIL" | jq -r '.extendedLocation.name // empty')
[[ -n "$CUSTOM_LOCATION" ]] || die "Could not determine custom location from AIO instance"

LOCATION=$(echo "$AIO_DETAIL" | jq -r '.location // empty')
[[ -n "$LOCATION" ]] || die "Could not determine location from AIO instance"

# Extract subscription from the instance resource ID
INSTANCE_ID=$(echo "$AIO_DETAIL" | jq -r '.id // empty')
SUBSCRIPTION=$(echo "$INSTANCE_ID" | sed -n 's|/subscriptions/\([^/]*\)/.*|\1|p')
[[ -n "$SUBSCRIPTION" ]] || die "Could not determine subscription from AIO instance"

# Resolve the Device Registry namespace
NAMESPACE_NAME=$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces?api-version=${API_VERSION}" \
  --query "value[0].name" -o tsv 2>/dev/null) || die "Failed to find Device Registry namespace"
[[ -n "$NAMESPACE_NAME" ]] || die "No Device Registry namespace found in resource group '$RESOURCE_GROUP'"

BASE_URI="https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces/${NAMESPACE_NAME}"

ok "Subscription:    $SUBSCRIPTION"
ok "Location:        $LOCATION"
ok "Namespace:       $NAMESPACE_NAME"
ok "Custom Location: ...$(echo "$CUSTOM_LOCATION" | sed 's|.*/||')"

# ── Get discovered assets via ARM REST API ────────────────────────────────────
step "Reading discovered assets from ARM"

DA_LIST=$(az rest --method GET \
  --url "${BASE_URI}/discoveredAssets?api-version=${API_VERSION}" \
  --output json) || die "Failed to list discovered assets"

# Filter by pattern
FILTERED=$(echo "$DA_LIST" | jq --arg pat "$FILTER_PATTERN" \
  '[.value[] | select(.name | test($pat))]')

COUNT=$(echo "$FILTERED" | jq length)
if [[ "$COUNT" -eq 0 ]]; then
  die "No discovered assets matching filter '$FILTER_PATTERN' found. Is the simulator running?"
fi
ok "Found $COUNT discovered assets to promote"

# ── Promote each asset ────────────────────────────────────────────────────────
step "Promoting discovered assets to managed Assets"

PROMOTED=0
SKIPPED=0
FAILED=0

for i in $(seq 0 $((COUNT - 1))); do
  DA=$(echo "$FILTERED" | jq ".[$i]")
  DA_NAME=$(echo "$DA" | jq -r '.name')

  # Skip if asset already exists
  if az rest --method GET \
    --url "${BASE_URI}/assets/${DA_NAME}?api-version=${API_VERSION}" \
    --output none 2>/dev/null; then
    ok "Exists:   $DA_NAME (skipped)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Extract fields (strip lastUpdatedOn — not valid in Asset schema)
  DEVICE_NAME=$(echo "$DA" | jq -r '.properties.deviceRef.deviceName')
  ENDPOINT_NAME=$(echo "$DA" | jq -r '.properties.deviceRef.endpointName')
  DATASETS=$(echo "$DA" | jq '[.properties.datasets[] | del(.lastUpdatedOn)]')

  # Generate a UUID for the asset
  ASSET_UUID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null \
    || uuidgen 2>/dev/null \
    || cat /proc/sys/kernel/random/uuid)

  # Build the ARM request body
  BODY=$(jq -n \
    --arg location "$LOCATION" \
    --arg cl "$CUSTOM_LOCATION" \
    --arg displayName "$DA_NAME" \
    --arg uuid "$ASSET_UUID" \
    --arg deviceName "$DEVICE_NAME" \
    --arg endpointName "$ENDPOINT_NAME" \
    --argjson datasets "$DATASETS" \
    '{
      location: $location,
      extendedLocation: {
        type: "CustomLocation",
        name: $cl
      },
      properties: {
        enabled: true,
        displayName: $displayName,
        externalAssetId: $uuid,
        uuid: $uuid,
        version: 1,
        deviceRef: {
          deviceName: $deviceName,
          endpointName: $endpointName
        },
        datasets: $datasets
      }
    }')

  TMPFILE=$(mktemp)
  echo "$BODY" > "$TMPFILE"

  if az rest --method PUT \
    --url "${BASE_URI}/assets/${DA_NAME}?api-version=${API_VERSION}" \
    --headers "Content-Type=application/json" \
    --body "@${TMPFILE}" \
    --output none; then
    ok "Promoted: $DA_NAME"
    PROMOTED=$((PROMOTED + 1))
  else
    warn "Failed:   $DA_NAME"
    FAILED=$((FAILED + 1))
  fi
  rm -f "$TMPFILE"
done

# ── Summary ──────────────────────────────────────────────────────────────────
step "Done"
ok "Promoted: $PROMOTED  |  Skipped: $SKIPPED  |  Failed: $FAILED"
echo ""
echo "Verify:"
echo "  # Check assets in the Operations Experience portal (https://iotoperations.azure.com)"
echo "  # Subscribe to unified/oee/# on the broker to confirm message forwarding"
