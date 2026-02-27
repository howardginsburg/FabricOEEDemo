# OEE Manufacturing Dashboard — Microsoft Fabric Tutorial

Build a real-time **Overall Equipment Effectiveness (OEE)** dashboard in Microsoft Fabric using the MQTTSimulator as your data source. By the end of this tutorial you will have:

- 10 simulated machines streaming telemetry into Fabric Eventstream
- A KQL Database (Eventhouse) storing and querying machine events
- A Real-Time Dashboard showing live OEE by line, by machine type, and per shift
- Activator alerts firing when a machine enters a Fault state

---

## Architecture

```
MQTTSimulator
  (14 devices: 10 machine + 4 maintenance CMMS)
       │
       │  HTTP REST  (Event Hub Protocol)
       ▼
Fabric Eventstream
  [Custom App source]
       │
       ├──[Filter: event_type = 'machine_telemetry']
       │         │
       │         ▼
       │   Eventhouse — KQL Database
       │     [MachineEvents]      ←── joins ── [MachineMaster]
       │     [ProductionSchedule] ←── reference (planned parts)
       │
       └──[Filter: event_type = 'maintenance_event']
                 │
                 ▼
           Eventhouse — KQL Database
             [MaintenanceEvents]
                 │
                 └── joins MachineEvents → MTTR, open fault detection

KQL Database → Real-Time Dashboard  (OEE, MTTR, schedule adherence)
KQL Database → Activator  (fault + unacknowledged maintenance alerts)
```

**OEE = Availability × Performance × Quality**

| Component | Formula |
|-----------|---------|
| Availability | Running messages ÷ total messages (per window) |
| Performance | ideal\_cycle\_time (from MachineMaster) ÷ avg(actual\_cycle\_time) — when Running |
| Quality | 1 − (sum(rejected\_parts) ÷ sum(total\_parts)) |

**Design principle:** The simulator sends only raw machine signals. `ideal_cycle_time` is engineering reference data stored in `MachineMaster`. `shift` is derived from the event timestamp in KQL. A single Eventstream fans out to two KQL tables via `event_type` routing.

---

## Machine Fleet

| Device IDs | Machine Type | Line | Expected OEE | Report Interval |
|------------|-------------|------|-------------|----------------|
| cnc-mill-001/002/003 | CNC-Mill | Line-A | ~88% | 30s |
| press-001/002 | Hydraulic-Press | Line-A | ~45% | 10s |
| robot-001/002/003 | Assembly-Robot | Line-B | ~92% | 15s |
| packaging-001/002 | Packaging-Line | Line-B | ~55% | 5s |
| maint-cnc-line-a | Maintenance (CNC) | Line-A | — | 180s |
| maint-press-line-a | Maintenance (Press) | Line-A | — | 90s |
| maint-robot-line-b | Maintenance (Robot) | Line-B | — | 240s |
| maint-pkg-line-b | Maintenance (Packaging) | Line-B | — | 90s |

---

## Prerequisites

- Microsoft Fabric capacity (F2 or higher) with Real-Time Intelligence enabled
- A Fabric workspace with contributor access
- Docker installed (to run the simulator container)

---

## Step 1 — Create the Eventstream

1. Open your Fabric workspace and select **+ New item → Eventstream**.
2. Name it **`manufacturing-telemetry`** and click **Create**.
3. In the Eventstream canvas, click **+ Add source → Custom endpoint**.
4. Name the source **`mqtt-simulator`** and click **Add**.
5. Click **Publish** (top toolbar) to save and activate the Eventstream. The **Keys** tab is only visible after the Eventstream has been published.
6. After publishing, click the **`mqtt-simulator`** source node on the canvas and open the **Keys** tab. Copy the **Connection string–primary key** (the full `Endpoint=sb://...;EntityPath=...` string). This single value contains everything the simulator needs, including the entity path.

---

## Step 2 — Configure the Simulator

1. Copy the sample configuration file and insert your connection string:

```bash
cp devices.sample.yaml devices.yaml
```

2. Open `devices.yaml` and replace the placeholder broker connection with the credentials copied in Step 1:

```yaml
brokers:
  manufacturing-eventhub:
    type: EventHub
    connection: "Endpoint=sb://<your-namespace>.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...;EntityPath=es_..."
```

All 14 devices already reference this named broker — no other changes are needed.

**Test the simulator:**
```bash
docker run -v "$(pwd)/devices.yaml:/app/devices.yaml" ghcr.io/howardginsburg/mqttsimulator:latest
```

You should see a live monitoring console displaying all 14 devices — each row shows the device ID, connection status, last message time, and message count updating in real time.

---

## Step 3 — Create the Eventhouse and KQL Database

1. In your Fabric workspace, select **+ New item → Eventhouse**.
2. Name it **`ManufacturingEH`** and click **Create**. A KQL Database named `ManufacturingEH` is created automatically.
3. Open the KQL Database and run the following in the **Explore your data** query window to create the tables and ingestion mapping:

```kql
// ---------------------------------------------------------------------------
// MachineEvents — raw machine telemetry routed from Eventstream
// ---------------------------------------------------------------------------
.create table MachineEvents (
    event_type:       string,
    device_id:        string,
    machine_type:     string,
    machine_status:   string,
    actual_cycle_time:real,
    total_parts:      long,
    rejected_parts:   long,
    line_id:          string,
    timestamp:        datetime
)

.create table MachineEvents ingestion json mapping 'MachineEventsMapping'
'['
'  {"column":"event_type",       "path":"$.event_type",       "datatype":"string"},'
'  {"column":"device_id",        "path":"$.deviceId",         "datatype":"string"},'
'  {"column":"machine_type",     "path":"$.machine_type",     "datatype":"string"},'
'  {"column":"machine_status",   "path":"$.machine_status",   "datatype":"string"},'
'  {"column":"actual_cycle_time","path":"$.actual_cycle_time","datatype":"real"},'
'  {"column":"total_parts",      "path":"$.total_parts",      "datatype":"long"},'
'  {"column":"rejected_parts",   "path":"$.rejected_parts",   "datatype":"long"},'
'  {"column":"line_id",          "path":"$.line_id",          "datatype":"string"},'
'  {"column":"timestamp",        "path":"$.timestamp",        "datatype":"datetime"}'
']'

// ---------------------------------------------------------------------------
// MaintenanceEvents — CMMS technician feed routed from the same Eventstream
// ---------------------------------------------------------------------------
.create table MaintenanceEvents (
    event_type:     string,
    machine_type:   string,
    line_id:        string,
    technician_id:  string,
    issue_type:     string,
    action:         string,
    timestamp:      datetime
)

.create table MaintenanceEvents ingestion json mapping 'MaintenanceEventsMapping'
'['
'  {"column":"event_type",    "path":"$.event_type",    "datatype":"string"},'
'  {"column":"machine_type",  "path":"$.machine_type",  "datatype":"string"},'
'  {"column":"line_id",       "path":"$.line_id",       "datatype":"string"},'
'  {"column":"technician_id", "path":"$.technician_id", "datatype":"string"},'
'  {"column":"issue_type",    "path":"$.issue_type",    "datatype":"string"},'
'  {"column":"action",        "path":"$.action",        "datatype":"string"},'
'  {"column":"timestamp",     "path":"$.timestamp",     "datatype":"datetime"}'
']'

// ---------------------------------------------------------------------------
// MachineMaster — engineering reference data (not from devices)
// Enriches MachineEvents with ideal_cycle_time, manufacturer info, etc.
// ---------------------------------------------------------------------------
.set-or-replace MachineMaster <|
    datatable(
        machine_type:string,
        ideal_cycle_time:real,
        manufacturer:string,
        install_year:int,
        maintenance_interval_hours:real
    )
    [
        "CNC-Mill",        45.0, "Haas",          2018, 500.0,
        "Hydraulic-Press",  8.0, "Schuler",        2015, 250.0,
        "Assembly-Robot",  20.0, "FANUC",          2021, 1000.0,
        "Packaging-Line",   3.0, "Bosch-Rexroth",  2019, 300.0,
    ]

// ---------------------------------------------------------------------------
// ProductionSchedule — planned output targets per line/shift
// Used to compute schedule adherence vs. actual production
// ---------------------------------------------------------------------------
.set ProductionSchedule <|
    datatable(line_id:string, shift:string, planned_parts:long)
    [
        "Line-A", "Day",    45000,
        "Line-A", "Night",  40000,
        "Line-B", "Day",   230000,
        "Line-B", "Night", 200000,
    ]
```

---

## Step 4 — Connect Eventstream to Eventhouse (with Routing)

Both machine telemetry and maintenance events flow through the **same** Eventstream source. Use a **Query** (SQL transform) operator to filter, rename columns, cast types, and route each `event_type` to the correct KQL table in one step.

> **Why Query instead of Filter + Manage Fields:** The Query operator lets you write a SQL `SELECT` statement with full control over column names, types, and filtering. This avoids Fabric's schema inference limitations in Manage Fields (no free-text entry, wrong type defaults, dependency on sampled events).

### 4.1 — Route machine telemetry to MachineEvents

1. In the Eventstream canvas, from the source node click **+** and add a **Query** operation.
2. In the Query pane, click **+ Add output** and name the output **`MachineEvents`**. This creates the destination node and makes `[MachineEvents]` available as the `INTO` target.
3. Enter the following SQL in the query editor:

```sql
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
FROM [manufacturing-telemetry-stream]
WHERE event_type = 'machine_telemetry'
```

4. Connect the `MachineEvents` output node to a **KQL Database** destination:
   - **KQL Database:** `ManufacturingEH`
   - **Table:** `MachineEvents`
   - **Input data format:** JSON

### 4.2 — Route maintenance events to MaintenanceEvents

1. From the same source node, click **+** again to add a **second Query** operation (branching independently).
2. In the Query pane, click **+ Add output** and name the output **`MaintenanceEvents`**.
3. Enter the following SQL:

```sql
SELECT
    event_type,
    machine_type,
    line_id,
    technician_id,
    issue_type,
    action,
    timestamp
INTO [MaintenanceEvents]
FROM [manufacturing-telemetry-stream]
WHERE event_type = 'maintenance_event'
```

4. Connect the `MaintenanceEvents` output node to a **KQL Database** destination:
   - **KQL Database:** `ManufacturingEH`
   - **Table:** `MaintenanceEvents`
   - **Input data format:** JSON

### 4.3 — Publish and verify

1. Click **Publish** in the Eventstream canvas.
2. Wait ~60 seconds, then run these verification queries in the KQL Database:

```kql
// Should show 10 distinct device IDs
MachineEvents
| summarize count() by device_id
| order by device_id asc

// Should show 4 technician feeds
MaintenanceEvents
| summarize count() by machine_type, technician_id
| order by machine_type asc
```

> **Tip:** If one table is empty, check that the Filter condition exactly matches the `event_type` string value (case-sensitive) and that both filters are connected to destinations before publishing.

---

## Step 5 — OEE KQL Queries

These queries power the Real-Time Dashboard tiles. Save them as **named queries** in the KQL Database for reuse.

All queries enrich raw telemetry by joining `MachineMaster` for `ideal_cycle_time` and deriving `shift` from the event timestamp.

### 5.1 — Availability (by line, last hour, 5-minute bins)

```kql
MachineEvents
| where timestamp > ago(1h)
| summarize
    total   = count(),
    running = countif(machine_status == "Running")
    by bin(timestamp, 5m), line_id
| extend availability = round(todouble(running) / todouble(total), 4)
| project timestamp, line_id, availability
| order by timestamp desc
```

### 5.2 — Performance (by line + machine type, last hour, 5-minute bins)

Joins `MachineMaster` to get `ideal_cycle_time`. Only meaningful when the machine is running.

```kql
MachineEvents
| where timestamp > ago(1h)
| where machine_status == "Running"
| join kind=inner MachineMaster on machine_type
| summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time)
    by bin(timestamp, 5m), line_id, machine_type
| extend performance = round(ideal / avg_actual, 4)
| project timestamp, line_id, machine_type, performance
| order by timestamp desc
```

### 5.3 — Quality (by line, last hour, 5-minute bins)

```kql
MachineEvents
| where timestamp > ago(1h)
| where total_parts > 0
| summarize
    total_sum    = sum(total_parts),
    rejected_sum = sum(rejected_parts)
    by bin(timestamp, 5m), line_id
| extend quality = round(1.0 - (todouble(rejected_sum) / todouble(total_sum)), 4)
| project timestamp, line_id, quality
| order by timestamp desc
```

### 5.4 — Combined OEE Score (by line, last hour, 5-minute bins)

Joins all three components into one table. This is the primary OEE tile query.

```kql
let avail =
    MachineEvents
    | where timestamp > ago(1h)
    | summarize total = count(), running = countif(machine_status == "Running")
        by bin(timestamp, 5m), line_id
    | extend availability = todouble(running) / todouble(total);
let perf =
    MachineEvents
    | where timestamp > ago(1h)
    | where machine_status == "Running"
    | join kind=inner MachineMaster on machine_type
    | summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time)
        by bin(timestamp, 5m), line_id
    | extend performance = ideal / avg_actual;
let qual =
    MachineEvents
    | where timestamp > ago(1h)
    | where total_parts > 0
    | summarize total_sum = sum(total_parts), rejected_sum = sum(rejected_parts)
        by bin(timestamp, 5m), line_id
    | extend quality = 1.0 - (todouble(rejected_sum) / todouble(total_sum));
avail
| join kind=leftouter perf  on timestamp, line_id
| join kind=leftouter qual  on timestamp, line_id
| extend oee = round(availability * performance * quality, 4)
| project timestamp, line_id, availability = round(availability, 4),
          performance = round(performance, 4), quality = round(quality, 4), oee
| order by timestamp desc
```

### 5.5 — Current Machine Status (live snapshot)

Most-recent status per device — used for the status table tile.

```kql
MachineEvents
| summarize arg_max(timestamp, machine_status, machine_type, line_id) by device_id
| project device_id, machine_type, line_id, machine_status, timestamp
| order by line_id asc, machine_type asc
```

### 5.6 — Fault Count by Machine (last hour)

```kql
MachineEvents
| where timestamp > ago(1h)
| where machine_status == "Fault"
| summarize fault_count = count() by device_id, machine_type, line_id
| order by fault_count desc
```

### 5.7 — Shift KPI Summary

Shift is derived from the event timestamp in KQL — not sent by the device.

```kql
MachineEvents
| where timestamp > ago(8h)
| where total_parts > 0
| extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
| summarize
    total_p    = sum(total_parts),
    rejected_p = sum(rejected_parts),
    faults     = countif(machine_status == "Fault")
    by shift, line_id
| extend quality = round(1.0 - (todouble(rejected_p) / todouble(total_p)), 4)
| project shift, line_id, total_p, rejected_p, quality, faults
| order by line_id asc, shift asc
```

### 5.8 — Materialized View for Performance

For dashboards querying frequently over large data, pre-aggregate into a materialized view.
Note: the view joins `MachineMaster` at creation time so `ideal_cycle_time` is baked in.

```kql
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
```

Then query the view instead of the raw table:

```kql
OEE_5min
| where timestamp > ago(1h)
| extend
    availability = todouble(running) / todouble(event_count),
    performance  = iif(avg_actual > 0, ideal / avg_actual, real(null)),
    quality      = iif(total_parts > 0, 1.0 - todouble(rejected) / todouble(total_parts), real(null))
| extend oee = round(availability * performance * quality, 4)
| project timestamp, device_id, machine_type, line_id, shift,
          availability = round(availability, 4),
          performance  = round(performance, 4),
          quality      = round(quality, 4), oee
| order by timestamp desc
```

### 5.9 — Mean Time to Repair (MTTR) by Machine Type

Joins `MachineEvents` (Fault occurrences) with `MaintenanceEvents` (Resolved actions) on `machine_type` and `line_id`. Demonstrates a **cross-table join between a live stream and a second live stream**.

```kql
let faults =
    MachineEvents
    | where timestamp > ago(24h)
    | where machine_status == "Fault"
    | project fault_time = timestamp, machine_type, line_id;
let resolutions =
    MaintenanceEvents
    | where timestamp > ago(24h)
    | where action == "Resolved"
    | project resolve_time = timestamp, machine_type, line_id;
faults
| join kind=inner resolutions on machine_type, line_id
| where resolve_time > fault_time
| extend mttr_minutes = datetime_diff('minute', resolve_time, fault_time)
| where mttr_minutes between (1 .. 480)    // exclude noise / same-minute events
| summarize avg_mttr = round(avg(mttr_minutes), 1), incidents = count()
    by machine_type, line_id
| join kind=leftouter MachineMaster on machine_type
| project machine_type, manufacturer, line_id, avg_mttr, incidents
| order by avg_mttr desc
```

### 5.10 — Actual vs. Planned Production (Schedule Adherence)

Compares cumulative `total_parts` per line against `ProductionSchedule` targets. Uses `max(total_parts)` per device as the end-of-window cumulative count, then sums across devices on the line.

```kql
MachineEvents
| where timestamp > ago(8h)
| extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
| summarize device_total = max(total_parts) by line_id, shift, device_id
| summarize actual_parts = sum(device_total) by line_id, shift
| join kind=inner ProductionSchedule on line_id, shift
| extend adherence_pct = round(todouble(actual_parts) / todouble(planned_parts) * 100, 1)
| project line_id, shift, actual_parts, planned_parts, adherence_pct
| order by line_id asc, shift asc
```

### 5.11 — OEE by Manufacturer (Equipment Age Analysis)

Enriches OEE results with `MachineMaster` manufacturer and install year — demonstrates a **multi-column reference join** for equipment benchmarking.

```kql
MachineEvents
| where timestamp > ago(1h)
| join kind=inner MachineMaster on machine_type
| summarize
    total        = count(),
    running      = countif(machine_status == "Running"),
    avg_actual   = avgif(actual_cycle_time, machine_status == "Running"),
    ideal        = avg(ideal_cycle_time),
    total_parts  = sum(total_parts),
    rejected     = sum(rejected_parts)
    by manufacturer, install_year, maintenance_interval_hours
| extend
    availability = round(todouble(running) / todouble(total), 4),
    performance  = iif(avg_actual > 0, round(ideal / avg_actual, 4), real(null)),
    quality      = iif(total_parts > 0, round(1.0 - todouble(rejected) / todouble(total_parts), 4), real(null))
| extend oee = round(availability * performance * quality, 4)
| project manufacturer, install_year, maintenance_interval_hours,
          availability, performance, quality, oee
| order by oee desc
```

### 5.12 — Open (Unacknowledged) Faults

Finds machines that are currently in Fault state with no corresponding Acknowledged or later maintenance event in the past 15 minutes.

```kql
let recent_faults =
    MachineEvents
    | where timestamp > ago(15m)
    | where machine_status == "Fault"
    | summarize last_fault = max(timestamp) by machine_type, line_id;
let acknowledged =
    MaintenanceEvents
    | where timestamp > ago(15m)
    | where action in ("Acknowledged", "InProgress", "Resolved")
    | summarize last_ack = max(timestamp) by machine_type, line_id;
recent_faults
| join kind=leftouter acknowledged on machine_type, line_id
| where isnull(last_ack) or last_ack < last_fault
| extend minutes_unacknowledged = datetime_diff('minute', now(), last_fault)
| project machine_type, line_id, last_fault, minutes_unacknowledged
| order by minutes_unacknowledged desc
```

---

## Step 6 — Build the Real-Time Dashboard

There are two ways to create the dashboard:

- **Option A — Build it manually** by adding each tile and query yourself. This is the best way to understand how Real-Time Dashboards work.
- **Option B — Import the pre-built template** from `oee-dashboard.template.json` for a quick start.

### Option A — Manual Dashboard Build

1. In your Fabric workspace, select **+ New item → Real-Time Dashboard**.
2. Name it **`OEE Manufacturing Dashboard`** and click **Create**.
3. Click **+ Add data source → KQL Database** and select `ManufacturingEH`.

### Tile 1 — OEE Trend (Line Chart)

```kql
let avail =
    MachineEvents
    | where timestamp > ago(1h)
    | summarize total = count(), running = countif(machine_status == "Running")
        by bin(timestamp, 5m), line_id
    | extend availability = todouble(running) / todouble(total);
let perf =
    MachineEvents
    | where timestamp > ago(1h)
    | where machine_status == "Running"
    | join kind=inner MachineMaster on machine_type
    | summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time)
        by bin(timestamp, 5m), line_id
    | extend performance = ideal / avg_actual;
let qual =
    MachineEvents
    | where timestamp > ago(1h)
    | where total_parts > 0
    | summarize total_sum = sum(total_parts), rejected_sum = sum(rejected_parts)
        by bin(timestamp, 5m), line_id
    | extend quality = 1.0 - (todouble(rejected_sum) / todouble(total_sum));
avail
| join kind=leftouter perf  on timestamp, line_id
| join kind=leftouter qual  on timestamp, line_id
| extend oee = round(availability * performance * quality, 4)
| project timestamp, line_id, availability = round(availability, 4),
          performance = round(performance, 4), quality = round(quality, 4), oee
| order by timestamp desc
```

- **Visualization:** Line chart
- **X-axis:** `timestamp`
- **Y-axis:** `oee`
- **Series:** `line_id`
- **Title:** "OEE by Production Line (last hour)"

### Tile 2 — Current OEE Score (Stat Cards)

For a single-number KPI card per line:

```kql
let avail =
    MachineEvents
    | where timestamp > ago(5m)
    | summarize total = count(), running = countif(machine_status == "Running") by line_id
    | extend availability = todouble(running) / todouble(total);
let perf =
    MachineEvents
    | where timestamp > ago(5m)
    | where machine_status == "Running"
    | join kind=inner MachineMaster on machine_type
    | summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time) by line_id
    | extend performance = ideal / avg_actual;
let qual =
    MachineEvents
    | where timestamp > ago(5m)
    | where total_parts > 0
    | summarize total_sum = sum(total_parts), rejected_sum = sum(rejected_parts) by line_id
    | extend quality = 1.0 - (todouble(rejected_sum) / todouble(total_sum));
avail
| join kind=leftouter perf on line_id
| join kind=leftouter qual on line_id
| extend oee = round(availability * performance * quality * 100, 1)
| project line_id, oee
```

- **Visualization:** Stat / Single value
- **Value:** `oee`
- **Series:** `line_id`
- **Title:** "Live OEE % (last 5 min)"
- **Conditional formatting:** Green ≥ 80, Yellow 60–79, Red < 60

### Tile 3 — Availability, Performance, Quality Breakdown (Bar Chart)

Use the Combined OEE query (5.4), latest bin only:

```kql
let avail =
    MachineEvents
    | where timestamp > ago(5m)
    | summarize total = count(), running = countif(machine_status == "Running") by line_id
    | extend metric = "Availability", value = round(todouble(running)/todouble(total)*100,1);
let perf =
    MachineEvents
    | where timestamp > ago(5m)
    | where machine_status == "Running"
    | join kind=inner MachineMaster on machine_type
    | summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time) by line_id
    | extend metric = "Performance", value = round(ideal/avg_actual*100,1);
let qual =
    MachineEvents
    | where timestamp > ago(5m)
    | where total_parts > 0
    | summarize total_sum = sum(total_parts), rejected_sum = sum(rejected_parts) by line_id
    | extend metric = "Quality", value = round((1.0 - todouble(rejected_sum)/todouble(total_sum))*100,1);
union avail, perf, qual
| project line_id, metric, value
| order by line_id asc, metric asc
```

- **Visualization:** Clustered bar chart
- **X-axis:** `metric`
- **Y-axis:** `value`
- **Series:** `line_id`
- **Title:** "OEE Components (live)"

### Tile 4 — Machine Status Table

```kql
MachineEvents
| summarize arg_max(timestamp, machine_status, machine_type, line_id) by device_id
| project device_id, machine_type, line_id, machine_status, timestamp
| order by line_id asc, machine_type asc
```

- **Visualization:** Table
- **Columns:** `device_id`, `machine_type`, `line_id`, `machine_status`, `timestamp`
- **Conditional formatting on `machine_status`:** Running = green, Idle = yellow, Fault = red
- **Title:** "Machine Status — Live"

### Tile 5 — Fault Count Heatmap / Bar

```kql
MachineEvents
| where timestamp > ago(1h)
| where machine_status == "Fault"
| summarize fault_count = count() by device_id, machine_type, line_id
| order by fault_count desc
```

- **Visualization:** Bar chart (horizontal)
- **X-axis:** `fault_count`
- **Y-axis:** `device_id`
- **Color by:** `machine_type`
- **Title:** "Faults by Device (last hour)"

### Tile 6 — Parts Produced Time Series

```kql
MachineEvents
| where timestamp > ago(1h)
| summarize parts = sum(total_parts) by bin(timestamp, 5m), line_id
| order by timestamp desc
```

- **Visualization:** Area chart
- **X-axis:** `timestamp`
- **Y-axis:** `parts`
- **Series:** `line_id`
- **Title:** "Parts Produced (last hour)"

### Tile 7 — Shift KPI Table

```kql
MachineEvents
| where timestamp > ago(8h)
| where total_parts > 0
| extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
| summarize
    total_p    = sum(total_parts),
    rejected_p = sum(rejected_parts),
    faults     = countif(machine_status == "Fault")
    by shift, line_id
| extend quality = round(1.0 - (todouble(rejected_p) / todouble(total_p)), 4)
| project shift, line_id, total_p, rejected_p, quality, faults
| order by line_id asc, shift asc
```

- **Visualization:** Table
- **Title:** "Shift Summary (last 8 hours)"

### Tile 8 — MTTR by Machine Type (Bar Chart)

```kql
let faults =
    MachineEvents
    | where timestamp > ago(24h)
    | where machine_status == "Fault"
    | project fault_time = timestamp, machine_type, line_id;
let resolutions =
    MaintenanceEvents
    | where timestamp > ago(24h)
    | where action == "Resolved"
    | project resolve_time = timestamp, machine_type, line_id;
faults
| join kind=inner resolutions on machine_type, line_id
| where resolve_time > fault_time
| extend mttr_minutes = datetime_diff('minute', resolve_time, fault_time)
| where mttr_minutes between (1 .. 480)
| summarize avg_mttr = round(avg(mttr_minutes), 1), incidents = count()
    by machine_type, line_id
| join kind=leftouter MachineMaster on machine_type
| project machine_type, manufacturer, line_id, avg_mttr, incidents
| order by avg_mttr desc
```

- **Visualization:** Bar chart (horizontal)
- **X-axis:** `avg_mttr`
- **Y-axis:** `machine_type`
- **Color by:** `manufacturer`
- **Title:** "Avg. Time to Repair by Machine Type (last 24h, minutes)"

### Tile 9 — Schedule Adherence (Stat Cards)

```kql
MachineEvents
| where timestamp > ago(8h)
| extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
| summarize device_total = max(total_parts) by line_id, shift, device_id
| summarize actual_parts = sum(device_total) by line_id, shift
| join kind=inner ProductionSchedule on line_id, shift
| extend adherence_pct = round(todouble(actual_parts) / todouble(planned_parts) * 100, 1)
| project line_id, shift, actual_parts, planned_parts, adherence_pct
| order by line_id asc, shift asc
```

- **Visualization:** Stat / Single value per row
- **Value:** `adherence_pct`
- **Series:** `line_id` + `shift`
- **Title:** "Production Schedule Adherence %"
- **Conditional formatting:** Green ≥ 95, Yellow 80–94, Red < 80

### Tile 10 — OEE by Manufacturer (Table)

```kql
MachineEvents
| where timestamp > ago(1h)
| join kind=inner MachineMaster on machine_type
| summarize
    total        = count(),
    running      = countif(machine_status == "Running"),
    avg_actual   = avgif(actual_cycle_time, machine_status == "Running"),
    ideal        = avg(ideal_cycle_time),
    total_parts  = sum(total_parts),
    rejected     = sum(rejected_parts)
    by manufacturer, install_year, maintenance_interval_hours
| extend
    availability = round(todouble(running) / todouble(total), 4),
    performance  = iif(avg_actual > 0, round(ideal / avg_actual, 4), real(null)),
    quality      = iif(total_parts > 0, round(1.0 - todouble(rejected) / todouble(total_parts), 4), real(null))
| extend oee = round(availability * performance * quality, 4)
| project manufacturer, install_year, maintenance_interval_hours,
          availability, performance, quality, oee
| order by oee desc
```

- **Visualization:** Table
- **Columns:** `manufacturer`, `install_year`, `maintenance_interval_hours`, `availability`, `performance`, `quality`, `oee`
- **Conditional formatting on `oee`:** Green ≥ 0.80, Yellow 0.60–0.79, Red < 0.60
- **Title:** "OEE by Equipment Manufacturer"

### Dashboard Auto-Refresh

Set the dashboard auto-refresh to **30 seconds** via **Dashboard settings → Auto refresh → 30s** to keep all tiles live.

### Option B — Import the Pre-Built Template

The pre-built template `oee-dashboard.template.json` includes more tiles than the 10 defined above — additional visualizations across two pages (OEE Overview and Maintenance Deep-Dive). To use it:

1. Copy the template to create your dashboard file:
   ```bash
   cp oee-dashboard.template.json oee-dashboard.json
   ```
2. Open `oee-dashboard.json` and replace `__CLUSTER_URI__` with your Eventhouse **Query URI** and `__DATABASE_ID__` with your KQL Database ID.
   Find the Query URI in Fabric: open **ManufacturingEH** → **Overview** → copy the **Query URI**
   (format: `https://<id>.kusto.fabric.microsoft.com`).
3. In your Fabric workspace, select **+ New item → Real-Time Dashboard**.
4. Name it **`OEE Manufacturing Dashboard`** and click **Create**.
5. In the top toolbar click the **pencil (edit)** icon, then **File → Open file** and upload `oee-dashboard.json`.
6. Fabric will prompt you to re-link the data source — select **ManufacturingEH** and click **Apply**.
7. Click **Save** and set auto-refresh to **30s** via **Dashboard settings**.

---

## Step 7 — Configure Activator Alerts

Activator monitors a stream and fires actions when conditions are met.

### 7.1 — Create an Activator from Eventstream

1. In the Eventstream canvas, click **+ Add destination → Activator**.
2. Name it **`MachineAlerts`** and click **Add**.
3. Open the Activator item in your workspace.

### 7.2 — Fault Detection Rule

1. In the Activator, click **+ New rule**.
2. Configure:
   - **Event column to monitor:** `machine_status`
   - **Condition:** `Is equal to` → `Fault`
   - **Group by device (unique object):** `device_id`
   - **Trigger:** When condition **becomes true** (fires once on transition, not on every fault message)
3. Under **Action**, select **Send Teams message** (or Email) and set the message body:
   ```
   ⚠️ FAULT DETECTED
   Device: {{device_id}}
   Type:   {{machine_type}}
   Line:   {{line_id}}
   Time:   {{timestamp}}
   ```

### 7.3 — Low OEE Alert (KQL-based)

For a more sophisticated alert, create an Activator rule sourced from the KQL Database:

1. In the Activator, click **+ New rule → KQL source**.
2. Select **`ManufacturingEH`** database and enter:

```kql
OEE_5min
| where timestamp > ago(6m) and timestamp <= ago(1m)
| extend
    availability = todouble(running) / todouble(event_count),
    performance  = iif(avg_actual > 0, ideal / avg_actual, real(null)),
    quality      = iif(total_parts > 0, 1.0 - todouble(rejected) / todouble(total_parts), real(null))
| extend oee = availability * performance * quality
| where oee < 0.60
| project device_id, line_id, machine_type, oee = round(oee * 100, 1)
```

3. Configure:
   - **Group by:** `device_id`
   - **Trigger:** When condition **becomes true**
   - **Action:** Teams message `OEE dropped below 60% for {{device_id}} on {{line_id}}: {{oee}}%`

### 7.4 — Unacknowledged Fault Alert (cross-table KQL)

Fires when a machine has been in Fault state for more than 10 minutes with no maintenance acknowledgement. This rule **joins two live tables** inside Activator.

1. In the Activator, click **+ New rule → KQL source**.
2. Select **`ManufacturingEH`** database and enter:

```kql
let recent_faults =
    MachineEvents
    | where timestamp > ago(15m)
    | where machine_status == "Fault"
    | summarize last_fault = max(timestamp) by machine_type, line_id;
let acknowledged =
    MaintenanceEvents
    | where timestamp > ago(15m)
    | where action in ("Acknowledged", "InProgress", "Resolved")
    | summarize last_ack = max(timestamp) by machine_type, line_id;
recent_faults
| join kind=leftouter acknowledged on machine_type, line_id
| where isnull(last_ack) or last_ack < last_fault
| extend minutes_unacknowledged = datetime_diff('minute', now(), last_fault)
| where minutes_unacknowledged >= 10
| project machine_type, line_id, last_fault, minutes_unacknowledged
```

3. Configure:
   - **Group by:** `machine_type`, `line_id`
   - **Trigger:** When condition **becomes true**
   - **Action:** Teams message `⚠️ UNACKNOWLEDGED FAULT: {{machine_type}} on {{line_id}} has been faulted for {{minutes_unacknowledged}} minutes with no maintenance response.`

---

## Step 8 — Run the Demo

### Start the Simulator

Start the simulator container as described in Step 2. The console shows a live monitoring table of all **14 devices** (10 machine + 4 maintenance) — status, last message time, and message count.


---

## Appendix — Telemetry Schema Reference

### MachineEvents (routed from Eventstream: `event_type = machine_telemetry`)

| Field | Type | Description |
|-------|------|-------------|
| `event_type` | string | `machine_telemetry` (Eventstream routing key) |
| `deviceId` | string | Device identifier (e.g. `cnc-mill-001`) |
| `machine_type` | string | `CNC-Mill`, `Hydraulic-Press`, `Assembly-Robot`, `Packaging-Line` |
| `machine_status` | string | `Running`, `Idle`, `Fault` |
| `actual_cycle_time` | number | Measured seconds per unit this cycle |
| `total_parts` | integer | Cumulative parts counter |
| `rejected_parts` | integer | Parts rejected this cycle |
| `line_id` | string | `Line-A` or `Line-B` |
| `timestamp` | ISO 8601 | UTC timestamp at message generation |

### MaintenanceEvents (routed from Eventstream: `event_type = maintenance_event`)

| Field | Type | Description |
|-------|------|-------------|
| `event_type` | string | `maintenance_event` (Eventstream routing key) |
| `machine_type` | string | Machine type being maintained |
| `line_id` | string | `Line-A` or `Line-B` |
| `technician_id` | string | `T001`–`T004` (one technician per machine type) |
| `issue_type` | string | Fault category (e.g. `Tool-Wear`, `Pressure-Loss`, `Gripper-Failure`, `Conveyor-Jam`) |
| `action` | string | `Acknowledged`, `InProgress`, `Resolved` — one unique stage per incident |
| `timestamp` | ISO 8601 | UTC timestamp |

### MachineMaster (static reference table in KQL Database)

| Field | Type | Description |
|-------|------|-------------|
| `machine_type` | string | Join key to MachineEvents |
| `ideal_cycle_time` | real | Target seconds per unit (engineering spec) |
| `manufacturer` | string | Equipment manufacturer |
| `install_year` | int | Year installed |
| `maintenance_interval_hours` | real | Recommended hours between scheduled maintenance |

### ProductionSchedule (static reference table in KQL Database)

| Field | Type | Description |
|-------|------|-------------|
| `line_id` | string | `Line-A` or `Line-B` |
| `shift` | string | `Day` or `Night` |
| `planned_parts` | long | Target cumulative parts per shift |

**Derived in KQL (not sent by any device):**

| Value | How |
|-------|-----|
| `ideal_cycle_time` | Joined from `MachineMaster` on `machine_type` |
| `shift` | `iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")` |
| `manufacturer`, `install_year` | Joined from `MachineMaster` on `machine_type` |

---

## Appendix — Troubleshooting

| Symptom | Check |
|---------|-------|
| Simulator exits immediately | `devices.yaml` connection string is still the placeholder — fill in real Fabric credentials |
| No rows in `MachineEvents` | Confirm Eventstream destination is published; check ingestion mapping name matches |
| OEE values > 1.0 | Performance can exceed 1.0 if actual cycle time < ideal — this is valid (machine running faster than spec) |
| Activator not firing | Verify Eventstream destination for Activator is published; check rule condition column name matches exactly |
| Dashboard tiles show "No data" | Extend the time range — tiles default to `ago(1h)`; if the simulator just started, use `ago(5m)` |
