#!/usr/bin/env bash
# =============================================================================
# 3-setup-translytical.sh — Provision OEE target write-back for Power BI
#
# Component C of the analytics/act extensions. Creates a dedicated Fabric SQL
# database (OeeGovernance), applies dbo.OeeTarget, deploys the Fabric User Data
# Function source for set_oee_target, and shortcuts the mirrored table into
# ManufacturingLH/Tables/dbo/OeeTarget for the existing Direct Lake model.
#
# Idempotent: re-running finds existing items and overwrites the shortcut.
#
# Prerequisites:
#   - Azure CLI (az) 2.x logged in ('az login')
#   - jq, base64, sed
#   - scripts/1-setup-fabric.sh and scripts/2-setup-powerbi.sh already run
#   - Optional: sqlcmd with Entra auth support to apply OeeTarget.schema.sql
#
# Usage:
#   bash scripts/3-setup-translytical.sh --workspace-name <NAME>
#   bash scripts/3-setup-translytical.sh --workspace-name <NAME> --use-device-code
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
TRANSLYTICAL_DIR="${REPO_ROOT}/powerbi/translytical"
UDF_SRC_DIR="${TRANSLYTICAL_DIR}/functions/set_oee_target"
SCHEMA_SQL="${TRANSLYTICAL_DIR}/OeeTarget.schema.sql"
LH_NAME="ManufacturingLH"
GOV_DB_NAME="OeeGovernance"
UDF_NAME="OeeTargetFunctions"
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

for cmd in az base64 jq sed curl; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done
[[ -d "$UDF_SRC_DIR" ]] || die "User Data Function folder not found: $UDF_SRC_DIR"
[[ -f "$SCHEMA_SQL" ]] || die "Schema file not found: $SCHEMA_SQL"

# ── Windows/Linux az temp-file handling (mirrors scripts/1-setup-fabric.sh) ─────
_AZ_BIN="$(command -v az)"
if [[ "$_AZ_BIN" == /mnt/* ]] || [[ "$_AZ_BIN" == *.exe ]]; then
  _AZ_IS_WINDOWS=true
  _WIN_TEMP="/mnt/c/Users/${USER}/AppData/Local/Temp"
  mkdir -p "$_WIN_TEMP" 2>/dev/null || _WIN_TEMP="/mnt/c/Windows/Temp"
else
  _AZ_IS_WINDOWS=false
  _WIN_TEMP="${REPO_ROOT}/.fabric-tmp"
  mkdir -p "$_WIN_TEMP"
fi
_win_tmpfile() { local f; f=$(mktemp "${_WIN_TEMP}/translytical.XXXXXX.json"); printf '%s' "$1" > "$f"; echo "$f"; }
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

# POST a JSON body and, when Fabric returns 202 (async), poll the long-running
# operation to completion. Surfaces the real error message on failure — unlike a
# fire-and-forget POST, which hides validation errors (e.g. UDF metadata checks).
# Body is streamed over stdin to avoid Windows/Linux temp-path conversion issues.
# Returns 0 on Succeeded/200/201, 1 otherwise (with a warn describing why).
LRO_ERROR=""
fabric_lro_post() {
  local uri="$1" body="$2" token hdr code op st r
  LRO_ERROR=""
  token=$(az account get-access-token --resource "$FABRIC_RESOURCE" --query accessToken -o tsv 2>/dev/null)
  [[ -z "$token" ]] && { LRO_ERROR="could not acquire access token"; return 1; }
  hdr=$(mktemp)
  code=$(printf '%s' "$body" | curl -s -o /dev/null -D "$hdr" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    --data-binary @- "${FABRIC_API}/${uri}" 2>/dev/null || echo "000")
  if [[ "$code" == "200" || "$code" == "201" ]]; then rm -f "$hdr"; return 0; fi
  if [[ "$code" != "202" ]]; then
    LRO_ERROR="HTTP $code"; rm -f "$hdr"; return 1
  fi
  op=$(tr -d '\r' < "$hdr" | awk -F': ' 'tolower($1)=="x-ms-operation-id"{print $2}' | head -1)
  rm -f "$hdr"
  [[ -z "$op" ]] && { LRO_ERROR="202 without an operation id"; return 1; }
  for _ in $(seq 1 40); do
    r=$(az rest --method GET --uri "${FABRIC_API}/operations/${op}" --resource "$FABRIC_RESOURCE" --output json 2>/dev/null || echo '{}')
    st=$(jq -r '.status // empty' <<<"$r")
    [[ "$st" == "Succeeded" ]] && return 0
    if [[ "$st" == "Failed" ]]; then
      LRO_ERROR=$(jq -r '.error.message // .error.errorCode // "unknown error"' <<<"$r")
      return 1
    fi
    sleep 8
  done
  LRO_ERROR="operation $op did not complete in time"; return 1
}

wait_for_item() {
  local list_path="$1" name="$2" type="${3:-}" max="${4:-180}" elapsed=0 id
  while (( elapsed < max )); do
    id=$(fabric_get "$list_path" | jq -r --arg n "$name" --arg t "$type" \
      '.value[] | select(.displayName==$n and ($t=="" or .type==$t)) | .id' 2>/dev/null | head -1 || true)
    [[ -n "$id" ]] && { echo "$id"; return 0; }
    sleep 8; elapsed=$((elapsed+8))
  done
  return 1
}

find_item_id() {
  local name="$1" type="$2"
  fabric_get "workspaces/$WS_ID/items" | jq -r --arg n "$name" --arg t "$type" \
    '.value[] | select(.displayName==$n and .type==$t) | .id' 2>/dev/null | head -1 || true
}

build_udf_parts() {
  local definition_content="$1"
  local parts='[]' f rel payload
  while IFS= read -r -d '' f; do
    rel="${f#"$UDF_SRC_DIR"/}"; rel="${rel//\\//}"
    [[ "$rel" == "requirements.txt" ]] && continue
    [[ "$rel" == "functions.py" ]] && continue
    if [[ "$rel" == "definition.json" ]]; then
      payload=$(printf '%s' "$definition_content" | base64 -w0)
    elif [[ "$rel" == "function_app.py" ]]; then
      payload=$(base64 -w0 "$UDF_SRC_DIR/functions.py")
    else
      payload=$(base64 -w0 "$f")
    fi
    parts=$(jq -c --arg p "$rel" --arg pl "$payload" \
      '. + [{path:$p,payload:$pl,payloadType:"InlineBase64"}]' <<<"$parts")
  done < <(find "$UDF_SRC_DIR" -type f -print0)
  echo "$parts"
}

DEPLOYED_ITEM_ID=""
deploy_item_soft() {
  local ws="$1" name="$2" type="$3" parts="$4" existing_id="$5"
  local body id
  DEPLOYED_ITEM_ID=""
  if [[ -n "$existing_id" ]]; then
    body=$(jq -n --argjson parts "$parts" '{definition:{parts:$parts}}')
    if fabric_lro_post "workspaces/$ws/items/$existing_id/updateDefinition?updateMetadata=true" "$body"; then
      DEPLOYED_ITEM_ID="$existing_id"; ok "$type '$name' updated (id=$existing_id)"; return 0
    fi
    warn "updateDefinition failed for $type '$name': ${LRO_ERROR:-unknown}"
    manual "Fix the source or publish via the portal / VS Code Fabric extension."
    DEPLOYED_ITEM_ID="$existing_id"
    return 1
  fi

  body=$(jq -n --arg n "$name" --arg t "$type" --argjson parts "$parts" \
    '{displayName:$n,type:$t,definition:{parts:$parts}}')
  if fabric_lro_post "workspaces/$ws/items" "$body"; then
    if id=$(wait_for_item "workspaces/$ws/items" "$name" "$type"); then
      DEPLOYED_ITEM_ID="$id"; ok "$type '$name' created (id=$id)"; return 0
    fi
    warn "$type '$name' reported success but did not appear yet — check the workspace."
    return 1
  fi
  warn "Could not create $type '$name': ${LRO_ERROR:-unknown}"
  return 1
}

# ── Step 0: Auth ──────────────────────────────────────────────────────────────
step "Authenticating"
[[ "$USE_DEVICE_CODE" == true ]] && az login --use-device-code --allow-no-subscriptions >/dev/null
az account show --output none 2>/dev/null || die "Not logged in — run 'az login' first."
ok "Authenticated"

# ── Step 1: Resolve workspace + lakehouse ─────────────────────────────────────
step "Resolving workspace and lakehouse"
WS_ID=$(fabric_get "workspaces" | jq -r --arg n "$WORKSPACE_NAME" \
  '.value[] | select(.displayName==$n) | .id' | head -1 || true)
[[ -z "$WS_ID" ]] && die "Workspace '$WORKSPACE_NAME' not found — check name and permissions."
ok "Workspace: '$WORKSPACE_NAME' ($WS_ID)"

LH=$(fabric_get "workspaces/$WS_ID/lakehouses" | jq -c --arg n "$LH_NAME" \
  '.value[] | select(.displayName==$n)' | head -1 || true)
[[ -z "$LH" ]] && die "Lakehouse '$LH_NAME' not found — run scripts/1-setup-fabric.sh first."
LH_ID=$(jq -r '.id' <<<"$LH")
ok "Lakehouse: '$LH_NAME' ($LH_ID)"

# ── Step 2: Create/find Fabric SQL database ───────────────────────────────────
step "Creating or finding Fabric SQL database '$GOV_DB_NAME'"
GOV_DB_ID=$(fabric_get "workspaces/$WS_ID/sqlDatabases" | jq -r --arg n "$GOV_DB_NAME" \
  '.value[] | select(.displayName==$n) | .id' 2>/dev/null | head -1 || true)
[[ -z "$GOV_DB_ID" ]] && GOV_DB_ID=$(find_item_id "$GOV_DB_NAME" "SQLDatabase")

if [[ -n "$GOV_DB_ID" ]]; then
  ok "SQLDatabase already exists (id=$GOV_DB_ID)"
else
  SQL_DB_BODY=$(jq -n --arg n "$GOV_DB_NAME" \
    '{displayName:$n,description:"OEE governance write-back store for Power BI translytical task flows."}')
  fabric_post "workspaces/$WS_ID/sqlDatabases" "$SQL_DB_BODY" >/dev/null
  GOV_DB_ID=$(wait_for_item "workspaces/$WS_ID/sqlDatabases" "$GOV_DB_NAME" "" 240 || true)
  [[ -z "$GOV_DB_ID" ]] && GOV_DB_ID=$(wait_for_item "workspaces/$WS_ID/items" "$GOV_DB_NAME" "SQLDatabase" 60 || true)
  if [[ -n "$GOV_DB_ID" ]]; then
    ok "SQLDatabase created (id=$GOV_DB_ID)"
  else
    warn "SQL database REST creation was not confirmed."
    manual "Create a Fabric SQL database named '$GOV_DB_NAME' in workspace '$WORKSPACE_NAME'."
    manual "Then re-run this script so it can apply dbo.OeeTarget, deploy the UDF, and create the shortcut."
  fi
fi

# ── Step 3: Apply dbo.OeeTarget schema when sqlcmd is available ────────────────
step "Applying OeeTarget schema"
if [[ -z "${GOV_DB_ID:-}" ]]; then
  warn "Skipping schema apply because '$GOV_DB_NAME' was not resolved."
else
  GOV_DETAIL=$(fabric_get "workspaces/$WS_ID/sqlDatabases/$GOV_DB_ID" || fabric_get "workspaces/$WS_ID/items/$GOV_DB_ID" || echo '{}')
  GOV_SQL_ENDPOINT=$(jq -r '.properties.serverFqdn // .properties.connectionString // .properties.sqlEndpointProperties.connectionString // empty' <<<"$GOV_DETAIL")
  GOV_SQL_DATABASE=$(jq -r --arg n "$GOV_DB_NAME" '.properties.databaseName // .displayName // $n' <<<"$GOV_DETAIL")
  SQLCMD_BIN=$(command -v sqlcmd || command -v sqlcmd.exe || true)
  _schema_applied=false
  if [[ -n "$SQLCMD_BIN" && -n "$GOV_SQL_ENDPOINT" ]]; then
    if "$SQLCMD_BIN" -S "$GOV_SQL_ENDPOINT" -d "$GOV_SQL_DATABASE" -G -b -i "$(_winpath "$SCHEMA_SQL")"; then
      ok "dbo.OeeTarget schema and seed rows applied (sqlcmd)"
      _schema_applied=true
    else
      warn "sqlcmd could not apply OeeTarget.schema.sql."
    fi
  fi
  # Fallback: apply the schema via pyodbc + Entra token when sqlcmd is unavailable/failed.
  if [[ "$_schema_applied" != true ]]; then
    _PY=$(command -v python3 || command -v python || true)
    if [[ -n "$_PY" ]] && "$_PY" -c 'import pyodbc' >/dev/null 2>&1; then
      if PYTHONUTF8=1 "$_PY" "$SCRIPT_DIR/apply-oee-target-schema.py" --workspace-name "$WORKSPACE_NAME"; then
        ok "dbo.OeeTarget schema and seed rows applied (pyodbc fallback)"
        _schema_applied=true
      else
        warn "pyodbc fallback could not apply the schema."
      fi
    fi
  fi
  if [[ "$_schema_applied" != true ]]; then
    warn "Automatic schema apply unavailable (need sqlcmd, or pyodbc + 'ODBC Driver 18 for SQL Server')."
    manual "Open '$GOV_DB_NAME' → T-SQL editor and run powerbi/translytical/OeeTarget.schema.sql,"
    manual "or run: python scripts/apply-oee-target-schema.py --workspace-name \"$WORKSPACE_NAME\""
  fi
fi

# ── Step 4: Deploy Fabric User Data Function source ───────────────────────────
step "Deploying User Data Function '$UDF_NAME'"
if [[ -z "${GOV_DB_ID:-}" ]]; then
  warn "Skipping UDF deployment because '$GOV_DB_NAME' was not resolved."
else
  UDF_DEFINITION=$(sed -e "s|__WORKSPACE_ID__|${WS_ID}|g" \
                       -e "s|__OEE_GOVERNANCE_ITEM_ID__|${GOV_DB_ID}|g" \
                       "$UDF_SRC_DIR/definition.json")
  UDF_PARTS=$(build_udf_parts "$UDF_DEFINITION")
  UDF_EXISTING=$(find_item_id "$UDF_NAME" "UserDataFunction")
  if deploy_item_soft "$WS_ID" "$UDF_NAME" "UserDataFunction" "$UDF_PARTS" "$UDF_EXISTING"; then
    UDF_ID="$DEPLOYED_ITEM_ID"
  else
    UDF_ID="$DEPLOYED_ITEM_ID"
    manual "If REST deployment is unavailable, create a User data functions item named '$UDF_NAME'."
    manual "Publish powerbi/translytical/functions/set_oee_target with connection alias 'OeeGovernance' to '$GOV_DB_NAME'."
  fi
fi

# ── Step 5: Shortcut OeeTarget into ManufacturingLH ───────────────────────────
step "Creating OneLake shortcut for OeeTarget"
if [[ -z "${GOV_DB_ID:-}" ]]; then
  warn "Skipping shortcut because '$GOV_DB_NAME' was not resolved."
else
  # The Fabric SQL DB mirrors dbo.OeeTarget to OneLake asynchronously (a minute or two
  # after the rows are written). Retry the shortcut so a fresh schema apply still succeeds.
  _sc_ok=false
  for _sc_try in 1 2 3 4 5 6; do
    _SC_BODY=$(jq -n --arg ws "$WS_ID" --arg db "$GOV_DB_ID" \
      '{path:"Tables/dbo",name:"OeeTarget",target:{oneLake:{workspaceId:$ws,itemId:$db,path:"Tables/dbo/OeeTarget"}}}')
    if fabric_post_none "workspaces/$WS_ID/items/$LH_ID/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" "$_SC_BODY"; then
      ok "OeeTarget shortcut created in $LH_NAME/Tables/dbo"
      _sc_ok=true; break
    fi
    # Older mirror layouts expose the table at Tables/OeeTarget (no schema segment).
    _SC_BODY_ALT=$(jq -n --arg ws "$WS_ID" --arg db "$GOV_DB_ID" \
      '{path:"Tables/dbo",name:"OeeTarget",target:{oneLake:{workspaceId:$ws,itemId:$db,path:"Tables/OeeTarget"}}}')
    if fabric_post_none "workspaces/$WS_ID/items/$LH_ID/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" "$_SC_BODY_ALT"; then
      ok "OeeTarget shortcut created in $LH_NAME/Tables/dbo"
      _sc_ok=true; break
    fi
    warn "OeeTarget mirror not ready yet (attempt $_sc_try) — waiting 30s..."
    sleep 30
  done
  if $_sc_ok; then
    # Refresh the lakehouse SQL analytics endpoint so Direct Lake sees dbo.OeeTarget.
    SEP_ID=$(fabric_get "workspaces/$WS_ID/sqlEndpoints" | jq -r --arg n "$LH_NAME" \
      '.value[] | select(.displayName==$n) | .id' | head -1 || true)
    [[ -n "$SEP_ID" ]] && fabric_post_none "workspaces/$WS_ID/sqlEndpoints/$SEP_ID/refreshMetadata?preview=true" '{}' \
      && ok "SQL analytics endpoint metadata refreshed" || true
  else
    warn "OeeTarget shortcut not confirmed — the mirrored Delta table may still be materializing."
    manual "In '$LH_NAME', create a OneLake shortcut named OeeTarget under Tables/dbo pointing to '$GOV_DB_NAME' → dbo.OeeTarget."
    manual "Re-run this script after dbo.OeeTarget appears in OneLake."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done"
ok "SQL database item : ${GOV_DB_ID:-not resolved}"
ok "UDF item          : ${UDF_ID:-manual/portal publish may be required}"
manual "Power BI wiring: open OEEAnalytics → Executive page (page-exec)."
manual "Add a numeric/what-if input for targetOee (0..1), use the Line slicer for lineId, and setBy as a text/default user value."
manual "Insert a Data function button, select workspace '$WORKSPACE_NAME' → '$UDF_NAME' → set_oee_target, and bind parameters."
manual "Publish the report; Power BI Desktop can configure the button, but execution happens after publish."
