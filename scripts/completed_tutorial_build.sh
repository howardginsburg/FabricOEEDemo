#!/usr/bin/env bash
# =============================================================================
# completed_tutorial_build.sh — End-to-end Fabric OEE demo provisioner
#
# Provisions: Eventhouse  →  KQL Database (3 tables + ref data + mat-view)
#             Eventstream (3 SQL query operators routed to KQL)
#             Real-Time Dashboard (import from template)
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

_win_tmpfile() {
  local f
  f=$(mktemp "${_WIN_TEMP}/fabric.XXXXXX.json")
  printf '%s' "$1" > "$f"
  echo "$f"
}

_winpath() { wslpath -w "$1" 2>/dev/null || echo "$1"; }

# ── az rest helpers ───────────────────────────────────────────────────────────
fabric_get() {
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

fabric_post_lro() {
  local tmp win max elapsed
  tmp=$(_win_tmpfile "$2")
  win=$(_winpath "$tmp")
  max="${3:-120}"

  local response
  response=$(az rest --method POST \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output json 2>/dev/null || echo '')
  rm -f "$tmp"

  if [[ -n "$response" ]]; then
    echo "$response"
    return 0
  fi

  return 0
}

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
step "Step 2 — Creating KQL Database"
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
  sleep 20
fi

# ── Step 2b: Apply KQL schema ─────────────────────────────────────────────────
step "Step 2b — Applying KQL schema (3 tables + ref data + materialized view)"

# --- MachineEvents table ---
kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MachineEvents (event_type:string, device_id:string, machine_type:string, machine_status:string, idle_reason:string, line_id:string, station_position:int, actual_cycle_time:real, input_buffer_count:int, output_buffer_count:int, buffer_capacity:int, total_parts_processed:long, rejected_parts:long, current_part_id:string, timestamp:datetime)' \
  "MachineEvents table"

read -r -d '' _ME_MAP <<'KQLEOF' || true
.create-or-alter table MachineEvents ingestion json mapping 'MachineEventsMapping'
'['
'  {"column":"event_type",           "path":"$.event_type",           "datatype":"string"},'
'  {"column":"device_id",            "path":"$.device_id",            "datatype":"string"},'
'  {"column":"machine_type",         "path":"$.machine_type",         "datatype":"string"},'
'  {"column":"machine_status",       "path":"$.machine_status",       "datatype":"string"},'
'  {"column":"idle_reason",          "path":"$.idle_reason",          "datatype":"string"},'
'  {"column":"line_id",              "path":"$.line_id",              "datatype":"string"},'
'  {"column":"station_position",     "path":"$.station_position",     "datatype":"int"},'
'  {"column":"actual_cycle_time",    "path":"$.actual_cycle_time",    "datatype":"real"},'
'  {"column":"input_buffer_count",   "path":"$.input_buffer_count",   "datatype":"int"},'
'  {"column":"output_buffer_count",  "path":"$.output_buffer_count",  "datatype":"int"},'
'  {"column":"buffer_capacity",      "path":"$.buffer_capacity",      "datatype":"int"},'
'  {"column":"total_parts_processed","path":"$.total_parts_processed","datatype":"long"},'
'  {"column":"rejected_parts",       "path":"$.rejected_parts",       "datatype":"long"},'
'  {"column":"current_part_id",      "path":"$.current_part_id",      "datatype":"string"},'
'  {"column":"timestamp",            "path":"$.timestamp",            "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ME_MAP" "MachineEvents mapping"

# --- PartEvents table ---
kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table PartEvents (event_type:string, part_id:string, line_id:string, station_position:int, machine_type:string, action:string, cycle_time:real, quality_pass:bool, timestamp:datetime)' \
  "PartEvents table"

read -r -d '' _PE_MAP <<'KQLEOF' || true
.create-or-alter table PartEvents ingestion json mapping 'PartEventsMapping'
'['
'  {"column":"event_type",       "path":"$.event_type",       "datatype":"string"},'
'  {"column":"part_id",          "path":"$.part_id",          "datatype":"string"},'
'  {"column":"line_id",          "path":"$.line_id",          "datatype":"string"},'
'  {"column":"station_position", "path":"$.station_position", "datatype":"int"},'
'  {"column":"machine_type",     "path":"$.machine_type",     "datatype":"string"},'
'  {"column":"action",           "path":"$.action",           "datatype":"string"},'
'  {"column":"cycle_time",       "path":"$.cycle_time",       "datatype":"real"},'
'  {"column":"quality_pass",     "path":"$.quality_pass",     "datatype":"bool"},'
'  {"column":"timestamp",        "path":"$.timestamp",        "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_PE_MAP" "PartEvents mapping"

# --- MaintenanceEvents table ---
kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MaintenanceEvents (event_type:string, work_order_id:string, device_id:string, machine_type:string, line_id:string, station_position:int, issue_type:string, action:string, technician_id:string, timestamp:datetime)' \
  "MaintenanceEvents table"

read -r -d '' _MAI_MAP <<'KQLEOF' || true
.create-or-alter table MaintenanceEvents ingestion json mapping 'MaintenanceEventsMapping'
'['
'  {"column":"event_type",       "path":"$.event_type",       "datatype":"string"},'
'  {"column":"work_order_id",    "path":"$.work_order_id",    "datatype":"string"},'
'  {"column":"device_id",        "path":"$.device_id",        "datatype":"string"},'
'  {"column":"machine_type",     "path":"$.machine_type",     "datatype":"string"},'
'  {"column":"line_id",          "path":"$.line_id",          "datatype":"string"},'
'  {"column":"station_position", "path":"$.station_position", "datatype":"int"},'
'  {"column":"issue_type",       "path":"$.issue_type",       "datatype":"string"},'
'  {"column":"action",           "path":"$.action",           "datatype":"string"},'
'  {"column":"technician_id",    "path":"$.technician_id",    "datatype":"string"},'
'  {"column":"timestamp",        "path":"$.timestamp",        "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_MAI_MAP" "MaintenanceEvents mapping"

# --- Reference data: LineMaster ---
read -r -d '' _LINE_MASTER <<'KQLEOF' || true
.set-or-replace LineMaster <|
    datatable(line_id:string, line_name:string, purpose:string, station_count:int)
    [
        "Line-A", "Precision Machining",   "Raw bar stock → machined shaft",              5,
        "Line-B", "Sheet Metal Forming",    "Sheet metal → stamped housing",               4,
        "Line-C", "Welding & Assembly",     "Components → welded subassembly",             6,
        "Line-D", "Surface Treatment",      "Raw part → painted and coated finished part", 7,
        "Line-E", "Electronics Assembly",   "Bare PCB → tested electronics module",        8,
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_LINE_MASTER" "LineMaster reference data"

# --- Reference data: StationMaster ---
read -r -d '' _STATION_MASTER <<'KQLEOF' || true
.set-or-replace StationMaster <|
    datatable(
        line_id:string, station_position:int, machine_type:string,
        ideal_cycle_time:real, manufacturer:string, install_year:int,
        buffer_capacity:int
    )
    [
        "Line-A", 1, "CNC-Lathe",            40.0, "Haas",          2018, 5,
        "Line-A", 2, "CNC-Mill",             45.0, "Haas",          2019, 5,
        "Line-A", 3, "Surface-Grinder",      35.0, "Okamoto",       2020, 5,
        "Line-A", 4, "Deburring-Station",    15.0, "Rösler",        2021, 5,
        "Line-A", 5, "CMM-Inspection",       60.0, "Zeiss",         2022, 5,
        "Line-B", 1, "Blanking-Press",        8.0, "Schuler",       2015, 5,
        "Line-B", 2, "Hydraulic-Press",      12.0, "Schuler",       2016, 5,
        "Line-B", 3, "Trimming-Station",     10.0, "Trumpf",        2017, 5,
        "Line-B", 4, "Quality-Inspection",   20.0, "Keyence",       2020, 5,
        "Line-C", 1, "Component-Loader",     10.0, "FANUC",         2019, 5,
        "Line-C", 2, "Welding-Robot",        25.0, "ABB",           2019, 5,
        "Line-C", 3, "Weld-Inspection",      30.0, "Yaskawa",       2020, 5,
        "Line-C", 4, "Fastening-Station",    15.0, "Atlas Copco",   2021, 5,
        "Line-C", 5, "Assembly-Robot",       20.0, "FANUC",         2021, 5,
        "Line-C", 6, "Leak-Test",            25.0, "ATEQ",          2022, 5,
        "Line-D", 1, "Surface-Prep",         20.0, "Wheelabrator",  2017, 5,
        "Line-D", 2, "Chemical-Wash",        30.0, "Dürr",          2017, 5,
        "Line-D", 3, "Primer-Application",   25.0, "Graco",         2018, 5,
        "Line-D", 4, "Paint-Booth",          40.0, "Dürr",          2018, 5,
        "Line-D", 5, "Curing-Oven",          90.0, "Ipsen",         2016, 5,
        "Line-D", 6, "Coating-Inspection",   15.0, "Keyence",       2021, 5,
        "Line-D", 7, "Final-Packaging",      10.0, "Bosch-Rexroth", 2020, 5,
        "Line-E", 1, "PCB-Loader",            5.0, "JUKI",          2021, 5,
        "Line-E", 2, "SMT-Placement",        15.0, "JUKI",          2021, 5,
        "Line-E", 3, "Reflow-Oven",          45.0, "Heller",        2020, 5,
        "Line-E", 4, "AOI-Inspection",       10.0, "Koh Young",     2022, 5,
        "Line-E", 5, "Through-Hole-Insert",  20.0, "Universal",     2019, 5,
        "Line-E", 6, "Wave-Solder",          35.0, "ERSA",          2019, 5,
        "Line-E", 7, "Functional-Test",      30.0, "National Instruments", 2020, 5,
        "Line-E", 8, "Conformal-Coat",       25.0, "Nordson",       2022, 5,
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_STATION_MASTER" "StationMaster reference data"

# --- Reference data: ProductionSchedule ---
read -r -d '' _PROD_SCHED <<'KQLEOF' || true
.set-or-replace ProductionSchedule <|
    datatable(line_id: string, shift: string, planned_parts: long)
    [
        "Line-A", "Day",    120,
        "Line-A", "Night",  100,
        "Line-B", "Day",    500,
        "Line-B", "Night",  450,
        "Line-C", "Day",    200,
        "Line-C", "Night",  180,
        "Line-D", "Day",    150,
        "Line-D", "Night",  130,
        "Line-E", "Day",    180,
        "Line-E", "Night",  150,
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_PROD_SCHED" "ProductionSchedule reference data"

# --- Materialized view ---
read -r -d '' _MATVIEW <<'KQLEOF' || true
.create materialized-view with (backfill=true, dimensionTables=['StationMaster']) OEE_5min on table MachineEvents
{
    MachineEvents
    | join kind=inner StationMaster on $left.line_id == $right.line_id, $left.station_position == $right.station_position
    | extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
    | summarize
        event_count  = count(),
        running      = countif(machine_status == "Running"),
        fault        = countif(machine_status == "Fault"),
        maintenance  = countif(machine_status == "Maintenance"),
        avg_actual   = avgif(actual_cycle_time, machine_status == "Running"),
        ideal        = avg(ideal_cycle_time),
        total_parts  = sum(total_parts_processed),
        rejected     = sum(rejected_parts)
        by bin(timestamp, 5m), device_id, machine_type, line_id, station_position, shift
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

  # Stream column schema — superset of all fields the simulator emits
  STREAM_COLS=$(jq -n '[
    {"name":"event_type",           "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"device_id",            "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"machine_type",         "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"machine_status",       "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"idle_reason",          "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"line_id",              "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"station_position",     "type":"BigInt",        "fields":null,"items":null},
    {"name":"actual_cycle_time",    "type":"Float",         "fields":null,"items":null},
    {"name":"input_buffer_count",   "type":"BigInt",        "fields":null,"items":null},
    {"name":"output_buffer_count",  "type":"BigInt",        "fields":null,"items":null},
    {"name":"buffer_capacity",      "type":"BigInt",        "fields":null,"items":null},
    {"name":"total_parts_processed","type":"BigInt",        "fields":null,"items":null},
    {"name":"rejected_parts",       "type":"BigInt",        "fields":null,"items":null},
    {"name":"current_part_id",      "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"part_id",              "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"action",               "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"cycle_time",           "type":"Float",         "fields":null,"items":null},
    {"name":"quality_pass",         "type":"Bit",           "fields":null,"items":null},
    {"name":"work_order_id",        "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"issue_type",           "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"technician_id",        "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"timestamp",            "type":"DateTime",      "fields":null,"items":null}
  ]')

  read -r -d '' MACH_SQL <<SQLEOF || true
SELECT
    event_type,
    device_id,
    machine_type,
    machine_status,
    idle_reason,
    line_id,
    CAST(station_position AS BIGINT)    AS station_position,
    actual_cycle_time,
    CAST(input_buffer_count AS BIGINT)  AS input_buffer_count,
    CAST(output_buffer_count AS BIGINT) AS output_buffer_count,
    CAST(buffer_capacity AS BIGINT)     AS buffer_capacity,
    CAST(total_parts_processed AS BIGINT) AS total_parts_processed,
    CAST(rejected_parts AS BIGINT)      AS rejected_parts,
    current_part_id,
    [timestamp]
INTO [MachineEvents]
FROM [${STREAM}]
WHERE event_type = 'machine_telemetry'
SQLEOF

  read -r -d '' PART_SQL <<SQLEOF || true
SELECT
    event_type,
    part_id,
    line_id,
    CAST(station_position AS BIGINT) AS station_position,
    machine_type,
    action,
    cycle_time,
    quality_pass,
    [timestamp]
INTO [PartEvents]
FROM [${STREAM}]
WHERE event_type = 'part_event'
SQLEOF

  read -r -d '' MAINT_SQL <<SQLEOF || true
SELECT
    event_type,
    work_order_id,
    device_id,
    machine_type,
    line_id,
    CAST(station_position AS BIGINT) AS station_position,
    issue_type,
    action,
    technician_id,
    [timestamp]
INTO [MaintenanceEvents]
FROM [${STREAM}]
WHERE event_type = 'maintenance_event'
SQLEOF

  TOPOLOGY=$(jq -n \
    --arg stream    "$STREAM" \
    --arg ws_id     "$WS_ID" \
    --arg db_id     "$DB_ID" \
    --arg db_name   "$DB_NAME" \
    --argjson cols  "$STREAM_COLS" \
    --arg mach_sql  "$MACH_SQL" \
    --arg part_sql  "$PART_SQL" \
    --arg maint_sql "$MAINT_SQL" \
    '{
      sources: [{name:"oee-simulator",type:"CustomEndpoint",properties:{}}],
      streams: [{
        name: $stream, type: "DefaultStream", properties: {},
        inputNodes: [{name:"oee-simulator"}]
      }],
      operators: [
        {
          name: "MachineTelemetryFilter", type: "SQL",
          inputNodes: [{name:$stream}],
          properties: {query:$mach_sql, advancedSettings:null},
          inputSchemas: [{name:$stream, schema:{columns:$cols}}]
        },
        {
          name: "PartEventFilter", type: "SQL",
          inputNodes: [{name:$stream}],
          properties: {query:$part_sql, advancedSettings:null},
          inputSchemas: [{name:$stream, schema:{columns:$cols}}]
        },
        {
          name: "MaintenanceEventFilter", type: "SQL",
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
          inputNodes: [{name:"MachineTelemetryFilter"}],
          inputSchemas: [{name:"MachineTelemetryFilter",schema:{columns:[]}}]
        },
        {
          name: "PartEvents", type: "Eventhouse",
          properties: {
            dataIngestionMode: "ProcessedIngestion",
            workspaceId: $ws_id, itemId: $db_id, databaseName: $db_name,
            tableName: "PartEvents",
            inputSerialization: {type:"Json",properties:{encoding:"UTF8"}}
          },
          inputNodes: [{name:"PartEventFilter"}],
          inputSchemas: [{name:"PartEventFilter",schema:{columns:[]}}]
        },
        {
          name: "MaintenanceEvents", type: "Eventhouse",
          properties: {
            dataIngestionMode: "ProcessedIngestion",
            workspaceId: $ws_id, itemId: $db_id, databaseName: $db_name,
            tableName: "MaintenanceEvents",
            inputSerialization: {type:"Json",properties:{encoding:"UTF8"}}
          },
          inputNodes: [{name:"MaintenanceEventFilter"}],
          inputSchemas: [{name:"MaintenanceEventFilter",schema:{columns:[]}}]
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

  # Activate
  step "Step 3b — Publishing Eventstream"
  sleep 15

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

  warn "IMPORTANT: The Eventstream sometimes does not start automatically."
  warn "Open the Eventstream in the Fabric UI and verify it shows 'Running'."
  warn "If it is stopped, click 'Publish' to activate it."
fi

# ── Step 4: Generate dashboard ────────────────────────────────────────────────
step "Step 4 — Generating oee-dashboard.json"
REPO_ROOT="${SCRIPT_DIR}/.."
DASH_OUT="${REPO_ROOT}/oee-dashboard.json"
DASH_TEMPLATE="${REPO_ROOT}/oee-dashboard.template.json"

if [[ -f "$DASH_TEMPLATE" ]]; then
  sed -e "s|__CLUSTER_URI__|${CLUSTER_URI}|g" \
      -e "s|__DATABASE_ID__|${DB_ID}|g" \
      -e "s|__WORKSPACE_ID__|${WS_ID}|g" \
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

# ── Step 6: Simulator instructions ────────────────────────────────────────────
step "Step 6 — Simulator configuration"

SAMPLE_FILE="${SCRIPT_DIR}/simulator/FabricOEESimulator/simulator.sample.yaml"
SIM_FILE="${SCRIPT_DIR}/simulator/FabricOEESimulator/simulator.yaml"

if [[ ! -f "$SAMPLE_FILE" ]]; then
  warn "simulator.sample.yaml not found in simulator/FabricOEESimulator/"
  manual "Copy simulator.sample.yaml to simulator.yaml and update the connection string"
else
  CONN_STR=""
  if [[ -t 0 ]]; then
    manual "Open manufacturing-telemetry Eventstream in Fabric"
    manual "Click 'oee-simulator' source node → Keys tab"
    manual "Copy 'Connection string–primary key'"
    read -rp "   Paste the connection string here (or press Enter to skip): " CONN_STR
  fi

  if [[ -n "$CONN_STR" ]]; then
    sed \
      -e 's|^    type: Console.*|    # type: Console|' \
      -e 's|^    # type: EventHub|    type: EventHub|' \
      -e "s|^    # connection: \"<YOUR_EVENTHUB_CONNECTION_STRING>\"|    connection: \"${CONN_STR}\"|" \
      "$SAMPLE_FILE" > "$SIM_FILE"
    ok "simulator.yaml generated with connection string"
  else
    cp "$SAMPLE_FILE" "$SIM_FILE"
    warn "simulator.yaml generated with placeholder — update the connection string before running"
    manual "Open manufacturing-telemetry Eventstream in Fabric"
    manual "Click 'oee-simulator' source node → Keys tab"
    manual "Copy 'Connection string–primary key' and replace <YOUR_EVENTHUB_CONNECTION_STRING> in simulator.yaml"
  fi
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
printf "\033[91m  ⚠  VERIFY EVENTSTREAM IS RUNNING:\033[0m\n"
manual "   Open the Eventstream in the Fabric UI and confirm it shows 'Running'."
manual "   If it is stopped or in draft state, click 'Publish' to activate it."
manual "   The Eventstream sometimes does not start automatically after provisioning."
printf "\n"
printf "\033[93m  REMAINING MANUAL STEPS:\033[0m\n\n"
manual "A) ACTIVATOR ALERTS  (Step 7 of tutorial)"
manual "   Eventstream canvas: + Add destination → Activator → name 'MachineAlerts'"
manual "   Add fault rule: machine_status = 'Fault', group by device_id"
manual "   Add low-OEE KQL rule: OEE_5min where oee < 0.60"
printf "\n"
manual "B) START THE SIMULATOR"
manual "   cd simulator/FabricOEESimulator && dotnet run"
manual "   (or with Docker: cd simulator && docker build -t oee-simulator . && docker run -it --rm -v \"\$(pwd)/FabricOEESimulator/simulator.yaml:/app/simulator.yaml\" oee-simulator)"
printf "\033[97m%s\033[0m\n\n" "$W"
