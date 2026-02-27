#!/usr/bin/env bash
# =============================================================================
# completed_tutorial_build.sh — End-to-end Fabric OEE demo provisioner (no Python dependency)
#
# Requires: az (Azure CLI 2.x), base64, sed (jq auto-installed if missing)
# Usage:    bash completed_tutorial_build.sh --workspace-name <NAME>
#           bash completed_tutorial_build.sh --workspace-name <NAME> --use-device-code
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_NAME=""
USE_DEVICE_CODE=false

# ── Colours ───────────────────────────────────────────────────────────────────
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

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in az base64; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

if ! command -v jq &>/dev/null; then
  step "Installing jq"
  sudo apt-get update -qq && sudo apt-get install -y -qq jq
  command -v jq &>/dev/null || die "Failed to install 'jq'."
  ok "jq installed"
fi

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# az is the Windows binary in WSL, so temp files for @file must be on the Windows
# filesystem. Derive a Windows-accessible temp dir from the current Windows user.
_WIN_TEMP="/mnt/c/Users/${USER}/AppData/Local/Temp"
mkdir -p "$_WIN_TEMP" 2>/dev/null || _WIN_TEMP="/mnt/c/Windows/Temp"

# Write content to a Windows-accessible temp file; return the file path.
_win_tmpfile() {
  local f
  f=$(mktemp "${_WIN_TEMP}/fabric.XXXXXX.json")
  printf '%s' "$1" > "$f"
  echo "$f"
}

# Convert a Linux path under /mnt/c to a Windows path (e.g. C:\Users\...).
_winpath() { wslpath -w "$1" 2>/dev/null || echo "$1"; }

# ── az rest helpers ───────────────────────────────────────────────────────────
fabric_get() {
  # Usage: fabric_get PATH
  local _stderr_file
  _stderr_file=$(mktemp)
  if az rest --method GET \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --output json 2>"$_stderr_file"; then
    rm -f "$_stderr_file"
  else
    local _rc=$?
    warn "GET $1 failed (exit $_rc): $(cat "$_stderr_file")"
    rm -f "$_stderr_file"
    return $_rc
  fi
}

fabric_post() {
  # Usage: fabric_post PATH BODY
  # Writes body to a Windows-accessible temp file (az is the Windows binary).
  local tmp win
  tmp=$(_win_tmpfile "$2")
  win=$(_winpath "$tmp")
  az rest --method POST \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output json 2>/dev/null || echo '{}'
  rm -f "$tmp"
}

# Long-running POST — returns operation ID from Location header, then polls to completion.
fabric_post_lro() {
  # Usage: fabric_post_lro PATH BODY [MAX_WAIT_SECS]
  local tmp win max elapsed op_id status
  tmp=$(_win_tmpfile "$2")
  win=$(_winpath "$tmp")
  max="${3:-120}"

  # Send the request and capture the Location header via --include (stderr has headers in verbose)
  local response
  response=$(az rest --method POST \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output json 2>/dev/null || echo '')
  rm -f "$tmp"

  # If az rest already followed the LRO and returned JSON, we're done.
  if [[ -n "$response" ]]; then
    echo "$response"
    return 0
  fi

  return 0
}

# Poll a list endpoint until an item with the given displayName appears.
# Prints the first matching item as compact JSON.
wait_for_item() {
  local list_path="$1" name="$2" max="${3:-300}" elapsed=0
  local result item
  while (( elapsed < max )); do
    result=$(fabric_get "$list_path" || echo '{"value":[]}')
    item=$(echo "$result" | jq -c --arg n "$name" \
      '.value[] | select(.displayName == $n)' 2>/dev/null | head -1 || true)
    if [[ -n "$item" ]]; then
      echo "$item"
      return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  die "Timed out waiting for '$name'"
}

# ── Kusto data-plane helper ───────────────────────────────────────────────────
kusto_run() {
  # kusto_run CLUSTER DB CMD DESC [soft=false]
  local cluster="$1" db="$2" cmd="$3" desc="$4" soft="${5:-false}"
  local body_tmp win err

  body_tmp=$(_win_tmpfile "$(jq -n --arg csl "$cmd" --arg db "$db" '{"csl":$csl,"db":$db}')")
  win=$(_winpath "$body_tmp")

  if err=$(az rest --method POST \
    --uri "${cluster}/v1/rest/mgmt" \
    --resource "$cluster" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output none 2>&1); then
    rm -f "$body_tmp"
    ok "$desc"
    return 0
  fi

  rm -f "$body_tmp"
  if [[ "$soft" == "true" ]]; then
    warn "$desc (skipped)"
    return 1
  fi
  die "KQL error [$desc]: ${err:0:300}"
}

# ── Step 0: Authenticate ──────────────────────────────────────────────────────
step "Authenticating"
[[ "$USE_DEVICE_CODE" == true ]] && \
  az login --use-device-code --allow-no-subscriptions >/dev/null

az account show --output none 2>/dev/null \
  || die "Not logged in — run 'az login' first."
ok "Authenticated"

# ── Find workspace ────────────────────────────────────────────────────────────
WORKSPACES=$(fabric_get "workspaces") \
  || die "Failed to list workspaces — check 'az login' and Fabric permissions."
WS_ID=$(echo "$WORKSPACES" | jq -r --arg n "$WORKSPACE_NAME" \
  '.value[] | select(.displayName == $n) | .id' | head -1 || true)
[[ -z "$WS_ID" ]] && \
  die "Workspace '$WORKSPACE_NAME' not found — check name and permissions."
ok "Workspace: '$WORKSPACE_NAME' ($WS_ID)"

# ── Step 1: Eventhouse ────────────────────────────────────────────────────────
step "Step 1 — Creating Eventhouse (ManufacturingEH)"
EH_LIST=$(fabric_get "workspaces/$WS_ID/eventhouses") \
  || die "Failed to list eventhouses — is the Fabric capacity active?"
EH_ID=$(echo "$EH_LIST" | jq -r \
  '.value[] | select(.displayName == "ManufacturingEH") | .id' | head -1 || true)
CLUSTER_URI=$(echo "$EH_LIST" | jq -r \
  '.value[] | select(.displayName == "ManufacturingEH") | .properties.queryServiceUri' | head -1 || true)

if [[ -n "$EH_ID" ]]; then
  ok "Eventhouse already exists  →  $CLUSTER_URI"
else
  fabric_post "workspaces/$WS_ID/eventhouses" '{"displayName":"ManufacturingEH"}' >/dev/null
  EH_JSON=$(wait_for_item "workspaces/$WS_ID/eventhouses" "ManufacturingEH")
  EH_ID=$(echo "$EH_JSON" | jq -r '.id')

  # Wait for cluster URI to be populated (provisioned after item appears)
  CLUSTER_URI=""
  for i in {1..30}; do
    EH_DETAIL=$(fabric_get "workspaces/$WS_ID/eventhouses/$EH_ID")
    CLUSTER_URI=$(echo "$EH_DETAIL" | jq -r '.properties.queryServiceUri // empty')
    [[ -n "$CLUSTER_URI" ]] && break
    sleep 10
  done
  [[ -z "$CLUSTER_URI" ]] && die "Eventhouse created but cluster URI not yet available"
  ok "Eventhouse created  →  $CLUSTER_URI"
fi

# ── Step 2: KQL Database ──────────────────────────────────────────────────────
step "Step 2 — Creating KQL Database with schema"
DB_NAME="ManufacturingEH"
DB_LIST=$(fabric_get "workspaces/$WS_ID/kqlDatabases") \
  || die "Failed to list KQL databases"
DB_ID=$(echo "$DB_LIST" | jq -r --arg n "$DB_NAME" \
  '.value[] | select(.displayName == $n) | .id' | head -1 || true)

if [[ -n "$DB_ID" ]]; then
  ok "KQL Database already exists (id=$DB_ID)"
else
  DB_PROPS_B64=$(b64 '{"databaseType":"ReadWrite","parentEventhouseItemId":"'"$EH_ID"'"}')
  DB_PAYLOAD=$(jq -n \
    --arg name "$DB_NAME" \
    --arg props "$DB_PROPS_B64" \
    '{displayName:$name,definition:{parts:[{path:"DatabaseProperties.json",payload:$props,payloadType:"InlineBase64"}]}}')
  fabric_post "workspaces/$WS_ID/kqlDatabases" "$DB_PAYLOAD" >/dev/null
  DB_JSON=$(wait_for_item "workspaces/$WS_ID/kqlDatabases" "$DB_NAME")
  DB_ID=$(echo "$DB_JSON" | jq -r '.id')
  ok "KQL Database created (id=$DB_ID)"
  sleep 20  # allow fully initialise before issuing commands
fi

# ── Step 2b: Apply KQL schema ─────────────────────────────────────────────────
step "Step 2b — Applying KQL schema (idempotent)"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MachineEvents (event_type:string, device_id:string, machine_type:string, machine_status:string, actual_cycle_time:real, total_parts:long, rejected_parts:long, line_id:string, timestamp:datetime)' \
  "MachineEvents table"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MaintenanceEvents (event_type:string, machine_type:string, line_id:string, technician_id:string, issue_type:string, action:string, timestamp:datetime)' \
  "MaintenanceEvents table"

read -r -d '' _ME_MAP <<'KQLEOF' || true
.create-or-alter table MachineEvents ingestion json mapping 'MachineEventsMapping'
'['
'  {"column":"event_type",        "path":"$.event_type",        "datatype":"string"},'
'  {"column":"device_id",         "path":"$.deviceId",          "datatype":"string"},'
'  {"column":"machine_type",      "path":"$.machine_type",      "datatype":"string"},'
'  {"column":"machine_status",    "path":"$.machine_status",    "datatype":"string"},'
'  {"column":"actual_cycle_time", "path":"$.actual_cycle_time", "datatype":"real"},'
'  {"column":"total_parts",       "path":"$.total_parts",       "datatype":"long"},'
'  {"column":"rejected_parts",    "path":"$.rejected_parts",    "datatype":"long"},'
'  {"column":"line_id",           "path":"$.line_id",           "datatype":"string"},'
'  {"column":"timestamp",         "path":"$.timestamp",         "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ME_MAP" "MachineEvents mapping"

read -r -d '' _MAI_MAP <<'KQLEOF' || true
.create-or-alter table MaintenanceEvents ingestion json mapping 'MaintenanceEventsMapping'
'['
'  {"column":"event_type",    "path":"$.event_type",    "datatype":"string"},'
'  {"column":"machine_type",  "path":"$.machine_type",  "datatype":"string"},'
'  {"column":"line_id",       "path":"$.line_id",       "datatype":"string"},'
'  {"column":"technician_id", "path":"$.technician_id", "datatype":"string"},'
'  {"column":"issue_type",    "path":"$.issue_type",    "datatype":"string"},'
'  {"column":"action",        "path":"$.action",        "datatype":"string"},'
'  {"column":"timestamp",     "path":"$.timestamp",     "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_MAI_MAP" "MaintenanceEvents mapping"

read -r -d '' _MACHINE_MASTER <<'KQLEOF' || true
.set-or-replace MachineMaster <|
    datatable(
        machine_type: string,
        ideal_cycle_time: real,
        manufacturer: string,
        install_year: int,
        maintenance_interval_hours: real
    )
    [
        "CNC-Mill",        45.0, "Haas",          2018, 500.0,
        "Hydraulic-Press",  8.0, "Schuler",        2015, 250.0,
        "Laser-Cutter",    12.0, "Trumpf",         2020, 400.0,
        "Assembly-Robot",  20.0, "FANUC",          2021, 1000.0,
        "Welding-Robot",   15.0, "ABB",            2019, 600.0,
        "Paint-Booth",     60.0, "Dürr",           2017, 200.0,
        "Heat-Treat-Oven",120.0, "Ipsen",          2016, 150.0,
        "Packaging-Line",   3.0, "Bosch-Rexroth",  2019, 300.0
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_MACHINE_MASTER" "MachineMaster reference data"

read -r -d '' _PROD_SCHED <<'KQLEOF' || true
.set-or-replace ProductionSchedule <|
    datatable(line_id: string, shift: string, planned_parts: long)
    [
        "Line-A", "Day",    45000,
        "Line-A", "Night",  40000,
        "Line-B", "Day",   230000,
        "Line-B", "Night", 200000,
        "Line-C", "Day",    18000,
        "Line-C", "Night",  15000,
        "Line-D", "Day",   350000,
        "Line-D", "Night", 300000
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_PROD_SCHED" "ProductionSchedule reference data"

read -r -d '' _MATVIEW <<'KQLEOF' || true
.create materialized-view with (backfill=true, dimensionTables=['MachineMaster']) OEE_5min on table MachineEvents
{
    MachineEvents
    | join kind=inner MachineMaster on machine_type
    | extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
    | summarize
        event_count  = count(),
        running      = countif(machine_status == "Running"),
        fault        = countif(machine_status == "Fault"),
        avg_actual   = avgif(actual_cycle_time, machine_status == "Running"),
        ideal        = avg(ideal_cycle_time),
        total_parts  = sum(total_parts),
        rejected     = sum(rejected_parts)
        by bin(timestamp, 5m), device_id, machine_type, line_id, shift
}
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_MATVIEW" "OEE_5min materialized view" "true" \
  || ok "OEE_5min materialized view already exists"

# ── Step 3: Eventstream ───────────────────────────────────────────────────────
step "Step 3 — Creating Eventstream (manufacturing-telemetry)"
ES_NAME="manufacturing-telemetry"
ES_LIST=$(fabric_get "workspaces/$WS_ID/eventstreams") \
  || die "Failed to list eventstreams"
ES_ID=$(echo "$ES_LIST" | jq -r --arg n "$ES_NAME" \
  '.value[] | select(.displayName == $n) | .id' | head -1 || true)

if [[ -n "$ES_ID" ]]; then
  ok "Eventstream already exists (id=$ES_ID)"
else
  STREAM="manufacturing-telemetry-stream"

  # Stream column schema shared by both SQL operators
  STREAM_COLS=$(jq -n '[
    {"name":"messageId",        "type":"BigInt",        "fields":null,"items":null},
    {"name":"deviceId",         "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"actual_cycle_time","type":"Float",         "fields":null,"items":null},
    {"name":"event_type",       "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"line_id",          "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"machine_status",   "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"machine_type",     "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"rejected_parts",   "type":"Float",         "fields":null,"items":null},
    {"name":"timestamp",        "type":"DateTime",      "fields":null,"items":null},
    {"name":"total_parts",      "type":"BigInt",        "fields":null,"items":null}
  ]')

  read -r -d '' MACH_SQL <<SQLEOF || true
SELECT
    event_type,
    deviceId          AS device_id,
    machine_type,
    machine_status,
    actual_cycle_time,
    CAST(total_parts    AS BIGINT) AS total_parts,
    CAST(rejected_parts AS BIGINT) AS rejected_parts,
    line_id,
    timestamp
INTO [MachineEvents]
FROM [${STREAM}]
WHERE event_type = 'machine_telemetry'
SQLEOF

  read -r -d '' MAINT_SQL <<SQLEOF || true
SELECT
    event_type,
    machine_type,
    line_id,
    technician_id,
    issue_type,
    action,
    timestamp
INTO [MaintenanceEvents]
FROM [${STREAM}]
WHERE event_type = 'maintenance_event'
SQLEOF

  TOPOLOGY=$(jq -n \
    --arg stream   "$STREAM" \
    --arg ws_id    "$WS_ID" \
    --arg db_id    "$DB_ID" \
    --arg db_name  "$DB_NAME" \
    --argjson cols "$STREAM_COLS" \
    --arg mach_sql "$MACH_SQL" \
    --arg maint_sql "$MAINT_SQL" \
    '{
      sources: [{name:"mqtt-simulator",type:"CustomEndpoint",properties:{}}],
      streams: [{
        name: $stream, type: "DefaultStream", properties: {},
        inputNodes: [{name:"mqtt-simulator"}]
      }],
      operators: [
        {
          name: "ManufacturingTelemetryFilter", type: "SQL",
          inputNodes: [{name:$stream}],
          properties: {query:$mach_sql, advancedSettings:null},
          inputSchemas: [{name:$stream, schema:{columns:$cols}}]
        },
        {
          name: "MaintenanceTelemetryFilter", type: "SQL",
          inputNodes: [{name:$stream}],
          properties: {query:$maint_sql, advancedSettings:null},
          inputSchemas: [{name:$stream, schema:{columns:$cols}}]
        }
      ],
      destinations: [
        {
          name: "MachineEvents", type: "Eventhouse",
          properties: {
            dataIngestionMode: "ProcessedIngestion",
            workspaceId: $ws_id, itemId: $db_id, databaseName: $db_name,
            tableName: "MachineEvents",
            inputSerialization: {type:"Json",properties:{encoding:"UTF8"}}
          },
          inputNodes: [{name:"ManufacturingTelemetryFilter"}],
          inputSchemas: [{name:"ManufacturingTelemetryFilter",schema:{columns:[]}}]
        },
        {
          name: "MaintenanceEvents", type: "Eventhouse",
          properties: {
            dataIngestionMode: "ProcessedIngestion",
            workspaceId: $ws_id, itemId: $db_id, databaseName: $db_name,
            tableName: "MaintenanceEvents",
            inputSerialization: {type:"Json",properties:{encoding:"UTF8"}}
          },
          inputNodes: [{name:"MaintenanceTelemetryFilter"}],
          inputSchemas: [{name:"MaintenanceTelemetryFilter",schema:{columns:[]}}]
        }
      ],
      compatibilityLevel: "1.1"
    }')

  TOPO_B64=$(b64 "$TOPOLOGY")

  PLATFORM_JSON=$(jq -n \
    --arg name "$ES_NAME" \
    '{
      "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
      "metadata": {
        "type": "Eventstream",
        "displayName": $name
      },
      "config": {
        "version": "2.0",
        "logicalId": "00000000-0000-0000-0000-000000000000"
      }
    }')
  PLATFORM_B64=$(b64 "$PLATFORM_JSON")

  ES_PAYLOAD=$(jq -n \
    --arg name "$ES_NAME" \
    --arg topo "$TOPO_B64" \
    --arg plat "$PLATFORM_B64" \
    '{displayName:$name,type:"Eventstream",definition:{parts:[
      {path:"eventstream.json",payload:$topo,payloadType:"InlineBase64"},
      {path:".platform",payload:$plat,payloadType:"InlineBase64"}
    ]}}')

  fabric_post "workspaces/$WS_ID/items" "$ES_PAYLOAD" >/dev/null
  ES_JSON=$(wait_for_item "workspaces/$WS_ID/eventstreams" "$ES_NAME")
  ES_ID=$(echo "$ES_JSON" | jq -r '.id')
  ok "Eventstream created (id=$ES_ID)"

  # Activate the Eventstream by re-posting its definition via the Eventstream-specific updateDefinition endpoint
  step "Step 3b — Publishing Eventstream"
  sleep 15  # allow Eventstream to fully initialise

  # Get current definition via Eventstream-specific endpoint
  ES_DEF=$(az rest --method POST \
    --uri "${FABRIC_API}/workspaces/$WS_ID/eventstreams/$ES_ID/getDefinition" \
    --resource "$FABRIC_RESOURCE" \
    --output json 2>/dev/null || true)

  if [[ -n "$ES_DEF" && "$ES_DEF" != "{}" ]]; then
    UPDATE_BODY=$(echo "$ES_DEF" | jq -c '{definition: .definition}')
    _utmp=$(_win_tmpfile "$UPDATE_BODY")
    _uwin=$(_winpath "$_utmp")
    az rest --method POST \
      --uri "${FABRIC_API}/workspaces/$WS_ID/eventstreams/$ES_ID/updateDefinition" \
      --resource "$FABRIC_RESOURCE" \
      --headers "Content-Type=application/json" \
      --body "@${_uwin}" \
      --output none 2>/dev/null || true
    rm -f "$_utmp"
    ok "Eventstream published via updateDefinition"
  else
    warn "Could not retrieve Eventstream definition — open it in Fabric and click Publish"
  fi
fi

# ── Step 4: Generate dashboard ────────────────────────────────────────────────
step "Step 4 — Generating oee-dashboard.json"
DASH_OUT="${SCRIPT_DIR}/oee-dashboard.json"
DASH_TEMPLATE="${SCRIPT_DIR}/oee-dashboard.template.json"

if [[ -f "$DASH_TEMPLATE" ]]; then
  sed -e "s|__CLUSTER_URI__|${CLUSTER_URI}|g" \
      -e "s|__DATABASE_ID__|${DB_ID}|g" \
      "$DASH_TEMPLATE" > "$DASH_OUT"
  ok "Dashboard JSON generated"
else
  warn "oee-dashboard.template.json not found — skipping dashboard generation."
fi

# ── Step 5: Import dashboard ──────────────────────────────────────────────────
step "Step 5 — Importing Real-Time Dashboard"
DASH_NAME="OEE Manufacturing Dashboard"

if [[ ! -f "$DASH_OUT" ]]; then
  warn "oee-dashboard.json not found — skipping import."
else
  # Use the items API (works without api-version) to check for existing dashboard
  ITEM_LIST=$(fabric_get "workspaces/$WS_ID/items" || echo '{"value":[]}')
  EXISTING_DASH=$(echo "$ITEM_LIST" | jq -r --arg n "$DASH_NAME" \
    '.value[] | select(.displayName == $n and .type == "KQLDashboard") | .id' 2>/dev/null | head -1 || true)

  if [[ -n "$EXISTING_DASH" ]]; then
    warn "Dashboard already exists — skipping import."
  else
    DASH_B64=$(base64 -w0 "$DASH_OUT")
    DASH_PAYLOAD=$(jq -n \
      --arg name    "$DASH_NAME" \
      --arg payload "$DASH_B64" \
      '{displayName:$name,type:"KQLDashboard",definition:{parts:[{path:"RealTimeDashboard.json",payload:$payload,payloadType:"InlineBase64"}]}}')

    DASH_RESULT=$(fabric_post "workspaces/$WS_ID/items" "$DASH_PAYLOAD")
    DASH_ID=$(echo "$DASH_RESULT" | jq -r '.id // .itemId // empty' 2>/dev/null | head -1 || true)
    if [[ -n "$DASH_ID" ]]; then
      ok "Dashboard imported (id=$DASH_ID)"
    else
      ok "Dashboard import submitted — verify in Fabric UI."
    fi
  fi
fi

# ── Step 6: Generate devices.yaml ─────────────────────────────────────────────
step "Step 6 — Generating devices.yaml"

SAMPLE_FILE="${SCRIPT_DIR}/devices.sample.yaml"
DEVICES_FILE="${SCRIPT_DIR}/devices.yaml"

if [[ ! -f "$SAMPLE_FILE" ]]; then
  die "devices.sample.yaml not found in ${SCRIPT_DIR}"
fi

# The Custom Endpoint connection string is not available via the Fabric REST API.
# If running interactively, prompt the user. Otherwise, leave the placeholder.
CONN_STR=""
if [[ -t 0 ]]; then
  manual "Open manufacturing-telemetry Eventstream in Fabric"
  manual "Click 'mqtt-simulator' source node → Keys tab"
  manual "Copy 'Connection string–primary key'"
  read -rp "   Paste the connection string here (or press Enter to skip): " CONN_STR
fi

if [[ -n "$CONN_STR" ]]; then
  sed "s|<YOUR_EVENTHUB_CONNECTION_STRING>|${CONN_STR}|g" "$SAMPLE_FILE" > "$DEVICES_FILE"
  ok "devices.yaml generated with connection string"
else
  cp "$SAMPLE_FILE" "$DEVICES_FILE"
  warn "devices.yaml generated with placeholder — update the connection string before running the simulator"
  manual "Open manufacturing-telemetry Eventstream in Fabric"
  manual "Click 'mqtt-simulator' source node → Keys tab"
  manual "Copy 'Connection string–primary key' and replace <YOUR_EVENTHUB_CONNECTION_STRING> in devices.yaml"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
W=$(printf '═%.0s' {1..65})
printf "\n\033[97m%s\033[0m\n"   "$W"
printf "\033[97m  Provisioning complete.  Summary:\033[0m\n"
printf "\033[97m%s\033[0m\n"     "$W"
printf "  Workspace ID       : %s\n" "$WS_ID"
printf "  Cluster URI        : %s\n" "$CLUSTER_URI"
printf "  KQL Database ID    : %s\n" "$DB_ID"
printf "  Eventstream ID     : %s\n" "$ES_ID"
printf "\n"
printf "\033[93m  REMAINING MANUAL STEPS:\033[0m\n\n"
manual "A) ACTIVATOR ALERTS  (Step 7 of tutorial)"
manual "   Eventstream canvas: + Add destination → Activator → name 'MachineAlerts'"
manual "   Add fault rule: machine_status = 'Fault', group by device_id"
manual "   Add low-OEE KQL rule: OEE_5min where oee < 0.60"
printf "\n"
manual "B) START THE SIMULATOR"
manual "   docker run -v \"\$(pwd)/devices.yaml:/app/devices.yaml\" ghcr.io/howardginsburg/mqttsimulator:latest"
printf "\033[97m%s\033[0m\n\n" "$W"
