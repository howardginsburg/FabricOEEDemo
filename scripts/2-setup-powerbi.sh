#!/usr/bin/env bash
# =============================================================================
# 2-setup-powerbi.sh — Deploy the OEE Analytics semantic model + Power BI report
#
# Component 0 of the analytics/act extensions. Deploys the checked-in PBIP project
# under powerbi/OEEAnalytics.* as two Fabric items:
#   • Semantic model "OEEAnalytics"  (Direct Lake over ManufacturingLH/dbo)
#   • Report          "OEEAnalytics"  (4 pages: Exec / Availability / Performance / Quality)
#
# What it does:
#   1. Resolves the workspace, the ManufacturingLH lakehouse (+ its SQL analytics
#      endpoint connection string) and the ManufacturingEH Eventhouse/KQL DB.
#   2. Materializes a Direct-Lake-friendly Station dimension: KQL table StationDim
#      = StationMaster extended with device_id, mirrored to OneLake and shortcut
#      into ManufacturingLH/Tables/dbo/StationDim (single-column key for the model).
#   3. Injects the SQL endpoint connection into the semantic model TMDL and
#      creates-or-updates the semantic model item via the Fabric items definition API.
#   4. Creates-or-updates the report item, rebinding it (byConnection) to the
#      deployed semantic model.
#
# Idempotent: re-running updates the existing items in place.
#
# Prerequisites:
#   - Azure CLI (az) 2.x logged in ('az login')
#   - jq, base64, sed
#   - scripts/1-setup-fabric.sh already run (ManufacturingLH + ManufacturingEH exist,
#     Silver tables + master dims mirrored to OneLake)
#
# Usage:
#   bash scripts/2-setup-powerbi.sh --workspace-name <NAME>
#   bash scripts/2-setup-powerbi.sh --workspace-name <NAME> --use-device-code
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
PBIP_DIR="${REPO_ROOT}/powerbi"
SM_DIR="${PBIP_DIR}/OEEAnalytics.SemanticModel"
RP_DIR="${PBIP_DIR}/OEEAnalytics.Report"
ITEM_NAME="OEEAnalytics"
LH_NAME="ManufacturingLH"
DB_NAME="ManufacturingEH"
WORKSPACE_NAME=""
USE_DEVICE_CODE=false

# ── Colours / logging ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi
ok()     { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
warn()   { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
die()    { printf "   ${RED}✗ ERROR:${RESET} %s\n" "$*" >&2; exit 1; }
step()   { printf "\n── %s\n" "$*"; }
manual() { printf "   ${YELLOW}→${RESET} %s\n" "$*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace-name)  WORKSPACE_NAME="$2"; shift 2 ;;
    --use-device-code) USE_DEVICE_CODE=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -z "$WORKSPACE_NAME" ]] && die "Usage: $0 --workspace-name <NAME>"

for cmd in az base64 jq sed; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done
[[ -d "$SM_DIR" ]] || die "Semantic model folder not found: $SM_DIR"
[[ -d "$RP_DIR" ]] || die "Report folder not found: $RP_DIR"

# ── Windows/Linux az temp-file handling (mirrors scripts/1-setup-fabric.sh) ─────
_AZ_BIN="$(command -v az)"
if [[ "$_AZ_BIN" == /mnt/* ]] || [[ "$_AZ_BIN" == *.exe ]]; then
  _AZ_IS_WINDOWS=true
  _WIN_TEMP="/mnt/c/Users/${USER}/AppData/Local/Temp"
  mkdir -p "$_WIN_TEMP" 2>/dev/null || _WIN_TEMP="/mnt/c/Windows/Temp"
else
  _AZ_IS_WINDOWS=false
  _WIN_TEMP="${TMPDIR:-/tmp}"
fi
_win_tmpfile() { local f; f=$(mktemp "${_WIN_TEMP}/pbi.XXXXXX.json"); printf '%s' "$1" > "$f"; echo "$f"; }
_winpath()     { if [[ "$_AZ_IS_WINDOWS" == true ]]; then wslpath -w "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }

fabric_get() {
  az rest --method GET --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" --output json 2>/dev/null
}
fabric_post() {
  local tmp win; tmp=$(_win_tmpfile "$2"); win=$(_winpath "$tmp")
  az rest --method POST --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" --body "@${win}" --output json 2>/dev/null || echo '{}'
  rm -f "$tmp"
}
fabric_post_none() {
  local tmp win; tmp=$(_win_tmpfile "$2"); win=$(_winpath "$tmp")
  if az rest --method POST --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" --body "@${win}" --output none 2>/dev/null; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}
kusto_run() {
  local cluster="$1" db="$2" cmd="$3" desc="$4" soft="${5:-false}" body_tmp win err
  body_tmp=$(_win_tmpfile "$(jq -n --arg csl "$cmd" --arg db "$db" '{"csl":$csl,"db":$db}')")
  win=$(_winpath "$body_tmp")
  if err=$(az rest --method POST --uri "${cluster}/v1/rest/mgmt" --resource "$cluster" \
    --headers "Content-Type=application/json" --body "@${win}" --output none 2>&1); then
    rm -f "$body_tmp"; ok "$desc"; return 0
  fi
  rm -f "$body_tmp"
  if [[ "$soft" == "true" ]]; then warn "$desc (skipped)"; return 1; fi
  die "KQL error [$desc]: ${err:0:300}"
}

# Run a KQL management/query command and return the raw JSON response (for reads).
kusto_query() {
  local cluster="$1" db="$2" cmd="$3" body_tmp win
  body_tmp=$(_win_tmpfile "$(jq -n --arg csl "$cmd" --arg db "$db" '{"csl":$csl,"db":$db}')")
  win=$(_winpath "$body_tmp")
  az rest --method POST --uri "${cluster}/v1/rest/mgmt" --resource "$cluster" \
    --headers "Content-Type=application/json" --body "@${win}" --output json 2>/dev/null || echo '{}'
  rm -f "$body_tmp"
}

wait_for_item() {
  local list_path="$1" name="$2" type="$3" max="${4:-180}" elapsed=0 id
  while (( elapsed < max )); do
    id=$(fabric_get "$list_path" | jq -r --arg n "$name" --arg t "$type" \
      '.value[] | select(.displayName==$n and .type==$t) | .id' 2>/dev/null | head -1 || true)
    [[ -n "$id" ]] && { echo "$id"; return 0; }
    sleep 8; elapsed=$((elapsed+8))
  done
  return 1
}

# Build a JSON array of {path,payload,payloadType} definition parts from a folder.
# $1 = item root dir, $2 = optional path of a file whose CONTENT is overridden by $3.
build_parts() {
  local root="$1" override_path="${2:-}" override_content="${3:-}"
  local parts='[]' f rel payload
  while IFS= read -r -d '' f; do
    rel="${f#"$root"/}"; rel="${rel//\\//}"
    if [[ -n "$override_path" && "$rel" == "$override_path" ]]; then
      payload=$(printf '%s' "$override_content" | base64 -w0)
    else
      payload=$(base64 -w0 "$f")
    fi
    parts=$(jq -c --arg p "$rel" --arg pl "$payload" \
      '. + [{path:$p,payload:$pl,payloadType:"InlineBase64"}]' <<<"$parts")
  done < <(find "$root" -type f -print0)
  echo "$parts"
}

deploy_item() {
  local ws="$1" name="$2" type="$3" parts="$4" existing_id="$5"
  local body resp id
  if [[ -n "$existing_id" ]]; then
    body=$(jq -n --argjson parts "$parts" '{definition:{parts:$parts}}')
    if fabric_post_none "workspaces/$ws/items/$existing_id/updateDefinition?updateMetadata=true" "$body"; then
      ok "$type '$name' updated (id=$existing_id)" >&2; echo "$existing_id"; return 0
    fi
    warn "updateDefinition failed for $type '$name' — will attempt create" >&2
  fi
  body=$(jq -n --arg n "$name" --arg t "$type" --argjson parts "$parts" \
    '{displayName:$n,type:$t,definition:{parts:$parts}}')
  resp=$(fabric_post "workspaces/$ws/items" "$body")
  id=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null | head -1)
  if [[ -z "$id" ]]; then
    id=$(wait_for_item "workspaces/$ws/items" "$name" "$type") || {
      warn "Create response: $(printf '%s' "$resp" | head -c 400)" >&2
      die "Timed out waiting for $type '$name' to be created"
    }
  fi
  ok "$type '$name' created (id=$id)" >&2
  printf '%s' "$id"
}

# ── Step 0: Auth ──────────────────────────────────────────────────────────────
step "Authenticating"
[[ "$USE_DEVICE_CODE" == true ]] && az login --use-device-code --allow-no-subscriptions >/dev/null
az account show --output none 2>/dev/null || die "Not logged in — run 'az login' first."
ok "Authenticated"

# ── Step 1: Resolve workspace + items ─────────────────────────────────────────
step "Resolving workspace, lakehouse, and Eventhouse"
WS_ID=$(fabric_get "workspaces" | jq -r --arg n "$WORKSPACE_NAME" \
  '.value[] | select(.displayName==$n) | .id' | head -1 || true)
[[ -z "$WS_ID" ]] && die "Workspace '$WORKSPACE_NAME' not found — check name and permissions."
ok "Workspace: '$WORKSPACE_NAME' ($WS_ID)"

LH=$(fabric_get "workspaces/$WS_ID/lakehouses" | jq -c --arg n "$LH_NAME" \
  '.value[] | select(.displayName==$n)' | head -1 || true)
[[ -z "$LH" ]] && die "Lakehouse '$LH_NAME' not found — run scripts/1-setup-fabric.sh first."
LH_ID=$(jq -r '.id' <<<"$LH")
# SQL analytics endpoint connection string (server). Poll until provisioned.
SQL_ENDPOINT=""; for _try in 1 2 3 4 5 6; do
  SQL_ENDPOINT=$(fabric_get "workspaces/$WS_ID/lakehouses/$LH_ID" \
    | jq -r '.properties.sqlEndpointProperties.connectionString // empty' 2>/dev/null || true)
  [[ -n "$SQL_ENDPOINT" ]] && break
  sleep 10
done
[[ -z "$SQL_ENDPOINT" ]] && die "Lakehouse SQL analytics endpoint not ready — retry in a minute."
ok "Lakehouse: '$LH_NAME' ($LH_ID)  →  SQL endpoint $SQL_ENDPOINT"

EH=$(fabric_get "workspaces/$WS_ID/eventhouses" | jq -c --arg n "$DB_NAME" \
  '.value[] | select(.displayName==$n)' | head -1 || true)
[[ -z "$EH" ]] && die "Eventhouse '$DB_NAME' not found — run scripts/1-setup-fabric.sh first."
EH_ID=$(jq -r '.id' <<<"$EH")
CLUSTER_URI=$(fabric_get "workspaces/$WS_ID/eventhouses/$EH_ID" \
  | jq -r '.properties.queryServiceUri // empty' 2>/dev/null || true)
[[ -z "$CLUSTER_URI" ]] && die "Could not resolve Eventhouse query URI."
DB_ID=$(fabric_get "workspaces/$WS_ID/kqlDatabases" | jq -r --arg n "$DB_NAME" \
  '.value[] | select(.displayName==$n) | .id' | head -1 || true)
[[ -z "$DB_ID" ]] && die "KQL database '$DB_NAME' not found."
ok "Eventhouse: '$DB_NAME' ($CLUSTER_URI)"

# ── Step 2: Add device_id to StationMaster (Direct-Lake single-column key) ─────
# device_id is a natural station attribute, so it lives on StationMaster itself —
# no duplicate dimension table.
step "Ensuring StationMaster.device_id (single-column station key)"
# Only (re)build when device_id is missing. An in-place schema change on a MIRRORED
# table breaks its OneLake Delta, so we DROP + recreate as a fresh table to get a
# clean mirror. The guard avoids resetting the mirror (a multi-minute re-export) on
# every re-run. Rebuild is non-self-referential: stage → drop → recreate → mirror.
HAS_DEVICE_ID=$(kusto_query "$CLUSTER_URI" "$DB_NAME" ".show table StationMaster cslschema" \
  | grep -c "device_id" 2>/dev/null || true)
if [[ "${HAS_DEVICE_ID:-0}" == "0" ]]; then
  read -r -d '' _STATION_STAGE <<'KQLEOF' || true
.set-or-replace StationMaster_stage <|
    StationMaster
    | project line_id, station_position, machine_type, ideal_cycle_time,
              manufacturer, install_year, buffer_capacity
    | extend device_id = strcat(tolower(line_id), "-station-", tostring(station_position))
KQLEOF
  kusto_run "$CLUSTER_URI" "$DB_NAME" "$_STATION_STAGE" "StationMaster stage (+device_id)"
  kusto_run "$CLUSTER_URI" "$DB_NAME" '.drop table StationMaster ifexists' "Drop StationMaster (reset mirror)"
  kusto_run "$CLUSTER_URI" "$DB_NAME" '.set-or-replace StationMaster <| StationMaster_stage' "Recreate StationMaster (+device_id)"
  kusto_run "$CLUSTER_URI" "$DB_NAME" '.drop table StationMaster_stage ifexists' "Drop StationMaster stage" true
  kusto_run "$CLUSTER_URI" "$DB_NAME" \
    '.alter-merge table StationMaster policy mirroring dataformat=parquet with (IsEnabled=true, Backfill=true, TargetLatencyInMinutes=5)' \
    "StationMaster OneLake mirroring (with backfill)"
  warn "StationMaster mirror re-export takes a few minutes; the model reframe at the end may"
  warn "need a re-run of this script (or a manual refresh) if Performance/OEE are blank."
else
  ok "StationMaster.device_id already present — skipping rebuild"
fi

# Refresh the StationMaster shortcut in ManufacturingLH/Tables/dbo (idempotent).
_SC_BODY=$(jq -n --arg ws "$WS_ID" --arg db "$DB_ID" \
  '{path:"Tables/dbo",name:"StationMaster",target:{oneLake:{workspaceId:$ws,itemId:$db,path:"Tables/StationMaster"}}}')
if fabric_post_none "workspaces/$WS_ID/items/$LH_ID/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" "$_SC_BODY"; then
  ok "StationMaster shortcut refreshed in $LH_NAME/Tables/dbo"
else
  warn "StationMaster shortcut not confirmed — Delta may still be materializing; re-run in a minute."
fi

# Clean up any StationDim duplicate from earlier versions of this script.
kusto_run "$CLUSTER_URI" "$DB_NAME" '.drop table StationDim ifexists' "Drop legacy StationDim table" true
az rest --method DELETE \
  --uri "${FABRIC_API}/workspaces/$WS_ID/items/$LH_ID/shortcuts/Tables/dbo/StationDim" \
  --resource "$FABRIC_RESOURCE" --output none 2>/dev/null \
  && ok "Removed legacy StationDim shortcut" || true

# Sync the lakehouse SQL analytics endpoint so the new StationMaster.device_id column
# is visible to Direct Lake (the endpoint caches schema and lags Delta changes).
SEP_ID=$(fabric_get "workspaces/$WS_ID/sqlEndpoints" | jq -r --arg n "$LH_NAME" \
  '.value[] | select(.displayName==$n) | .id' | head -1 || true)
if [[ -n "$SEP_ID" ]]; then
  if fabric_post_none "workspaces/$WS_ID/sqlEndpoints/$SEP_ID/refreshMetadata?preview=true" '{}'; then
    ok "SQL analytics endpoint metadata refreshed"
  else
    warn "SQL endpoint metadata refresh not confirmed — device_id may take a few minutes to appear."
  fi
else
  warn "SQL analytics endpoint id not found — skip metadata refresh."
fi

# ── Step 3: Deploy semantic model ─────────────────────────────────────────────
step "Deploying semantic model '$ITEM_NAME'"
EXPR_SRC="${SM_DIR}/definition/expressions.tmdl"
EXPR_INJECTED=$(sed -e "s|__SQL_ENDPOINT__|${SQL_ENDPOINT}|g" \
                    -e "s|__LAKEHOUSE_SQL_DB__|${LH_NAME}|g" "$EXPR_SRC")
SM_PARTS=$(build_parts "$SM_DIR" "definition/expressions.tmdl" "$EXPR_INJECTED")
SM_EXISTING=$(fabric_get "workspaces/$WS_ID/items" | jq -r --arg n "$ITEM_NAME" \
  '.value[] | select(.displayName==$n and .type=="SemanticModel") | .id' | head -1 || true)
SM_ID=$(deploy_item "$WS_ID" "$ITEM_NAME" "SemanticModel" "$SM_PARTS" "$SM_EXISTING")

# ── Step 4: Deploy report (rebound to the deployed semantic model) ────────────
step "Deploying report '$ITEM_NAME'"
PBIR_BYCONN=$(jq -n --arg id "$SM_ID" \
  '{version:"4.0",datasetReference:{byConnection:{connectionString:null,pbiServiceModelId:null,pbiModelVirtualServerName:"sobe_wowvirtualserver",pbiModelDatabaseName:$id,name:"EntityDataSource",connectionType:"pbiServiceXmlaStyleLive"}}}')
RP_PARTS=$(build_parts "$RP_DIR" "definition.pbir" "$PBIR_BYCONN")
RP_EXISTING=$(fabric_get "workspaces/$WS_ID/items" | jq -r --arg n "$ITEM_NAME" \
  '.value[] | select(.displayName==$n and .type=="Report") | .id' | head -1 || true)
RP_ID=$(deploy_item "$WS_ID" "$ITEM_NAME" "Report" "$RP_PARTS" "$RP_EXISTING")

# ── Step 5: Reframe the Direct Lake model so it loads the latest Delta ─────────
# The reframe is a background/enhanced refresh. It can transiently fail right after
# deploy while the lakehouse SQL analytics endpoint is still syncing the mirrored
# Delta tables ("cannot access the source Delta table ... referenced by table ..."),
# so we poll the result and retry a few times instead of firing and forgetting.
# NOTE: a failed reframe does NOT stop the report from opening — Direct Lake reads
# OneLake on demand with the viewer's identity at query time; the reframe only forces
# the model to pick up the newest Delta version immediately.
step "Reframing the Direct Lake semantic model"
PBI_RES="https://analysis.windows.net/powerbi/api"
PBI_TOKEN=$(az account get-access-token --resource "$PBI_RES" --query accessToken -o tsv 2>/dev/null || true)
if [[ -n "$PBI_TOKEN" ]]; then
  _reframe_ok=false
  for _rf_attempt in 1 2 3 4 5; do
    _rf_tmp=$(_win_tmpfile '{"type":"full"}'); _rf_win=$(_winpath "$_rf_tmp")
    az rest --method POST \
      --uri "https://api.powerbi.com/v1.0/myorg/datasets/$SM_ID/refreshes" \
      --resource "$PBI_RES" \
      --headers "Content-Type=application/json" --body "@${_rf_win}" --output none 2>/dev/null || true
    rm -f "$_rf_tmp"
    _rf_status=""; _rf_err=""
    for _rf_poll in $(seq 1 20); do
      _rf_hist=$(az rest --method GET \
        --uri "https://api.powerbi.com/v1.0/myorg/datasets/$SM_ID/refreshes?\$top=1" \
        --resource "$PBI_RES" --output json 2>/dev/null || echo '{}')
      _rf_status=$(jq -r '.value[0].status // empty' <<<"$_rf_hist")
      [[ "$_rf_status" == "Completed" ]] && break
      if [[ "$_rf_status" == "Failed" ]]; then
        _rf_err=$(jq -r '.value[0].serviceExceptionJson // empty' <<<"$_rf_hist")
        break
      fi
      sleep 6
    done
    if [[ "$_rf_status" == "Completed" ]]; then
      _reframe_ok=true; ok "Model reframed (attempt $_rf_attempt)"; break
    fi
    warn "Reframe attempt $_rf_attempt did not complete (status: ${_rf_status:-unknown})."
    sleep 15
  done
  if ! $_reframe_ok; then
    warn "Reframe did not succeed — this is usually the lakehouse SQL endpoint still syncing"
    warn "the mirrored Delta tables after deploy. The report still OPENS and queries data on"
    warn "demand; only immediate reframe is deferred."
    manual "Wait a few minutes (or start the simulator so telemetry streams), then re-run this"
    manual "script, or open the model in Fabric and click Refresh."
  fi
fi

# ── Step 6: Rebind the report to the model (safety net; last write) ───────────
# PRIMARY FIX is the report definition FORMAT: the checked-in report under
# powerbi/OEEAnalytics.Report uses the current PBIR schemas (version 2.0.0,
# report 3.3.0, page 2.1.0, visualContainer 2.12.0, Fluent2 base theme as a
# StaticResources part). Older PBIR (version 4.0.0 / *.1.0.0 schemas / a
# shared-theme-by-name) deploys an item the portal can't fully register, so it
# resolves the dataset object id as "undefined" and the report fails to open with
# "Failed to get access request info for this artifact" (a 405 on
# /metadata/accessrequest/2/undefined). With the modern format the report opens
# without any rebind.
# This Rebind is a harmless belt-and-suspenders re-link of report→dataset, kept as
# a safety net. It runs AFTER the reframe on purpose: a failed enhanced-refresh can
# reset a fresh rebind, so if a rebind is ever needed it must be the last write.
if [[ -n "$RP_ID" && -n "$SM_ID" ]]; then
  step "Rebinding report '$ITEM_NAME' to semantic model (safety net)"
  RB_TOKEN=$(az account get-access-token --resource "https://analysis.windows.net/powerbi/api" \
    --query accessToken -o tsv 2>/dev/null || true)
  if [[ -n "$RB_TOKEN" ]]; then
    _rb_tmp=$(_win_tmpfile "$(jq -n --arg id "$SM_ID" '{datasetId:$id}')"); _rb_win=$(_winpath "$_rb_tmp")
    if az rest --method POST \
      --uri "https://api.powerbi.com/v1.0/myorg/groups/$WS_ID/reports/$RP_ID/Rebind" \
      --resource "https://analysis.windows.net/powerbi/api" \
      --headers "Content-Type=application/json" --body "@${_rb_win}" --output none 2>/dev/null; then
      ok "Report rebound to semantic model (allow 1-2 min to propagate before first open)"
    else
      warn "Rebind call failed. If the report shows 'Failed to get access request info', run:"
      manual "az rest --method POST --uri \"https://api.powerbi.com/v1.0/myorg/groups/$WS_ID/reports/$RP_ID/Rebind\" --headers \"Content-Type=application/json\" --body '{\"datasetId\":\"$SM_ID\"}'"
    fi
    rm -f "$_rb_tmp"
  else
    warn "Could not acquire a Power BI token to rebind the report — open may fail until you rebind."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done"
ok "Semantic model id : $SM_ID"
ok "Report id         : $RP_ID"
manual "Open the report in Fabric: workspace '$WORKSPACE_NAME' → '$ITEM_NAME'."
manual "If the model shows no data, confirm ManufacturingLH OneLake shortcuts exist"
manual "for MachineEvents / PartEvents / MaintenanceEvents / the master dims / StationMaster."
manual "Direct Lake reads Delta via the SQL endpoint: $SQL_ENDPOINT"
manual "On first deploy the StationMaster mirror export can lag a few minutes; if Performance/"
manual "OEE are blank, wait and re-run this script (it will just reframe) or Refresh in Fabric."
