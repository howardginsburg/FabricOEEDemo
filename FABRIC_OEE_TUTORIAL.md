# OEE Manufacturing Dashboard — Microsoft Fabric Tutorial

Build a real-time **Overall Equipment Effectiveness (OEE)** dashboard in Microsoft Fabric that models **true production-line OEE** — parts flow sequentially through ordered stations, faults cascade starvation and blocking via bounded buffers, and maintenance work orders gate machine recovery. By the end of this tutorial you will have:

- 30 simulated machines across 5 production lines streaming telemetry into Fabric Eventstream
- Part-level tracking with unique IDs flowing through each station
- Cascading fault behavior — a downed machine starves downstream and blocks upstream
- Maintenance work orders that must be resolved before a machine can resume
- A KQL Database (Eventhouse) storing machine, part, and maintenance events
- A 5-page Real-Time Dashboard organized by stakeholder persona: Corporate Executive, Plant Manager, Line Manager, Maintenance Technician, and Quality / Station Worker
- Activator alerts firing when a machine enters a Fault state

---

## Architecture

```
.NET Simulator (5 production lines, 30 stations)
  Parts flow: Station 1 → [Buffer] → Station 2 → [Buffer] → ... → Station N
  Events: machine_telemetry | part_event | maintenance_event
       │
       │  Event Hub Protocol
       ▼
Fabric Eventstream
  [Custom App source]
       │
       ├──[Query: event_type = 'machine_telemetry'] ──► MachineEvents table
       │
       ├──[Query: event_type = 'part_event']         ──► PartEvents table
       │
       └──[Query: event_type = 'maintenance_event']  ──► MaintenanceEvents table

Eventhouse — KQL Database
  [StationMaster]       ← reference (per-station ideal cycle times)
  [LineMaster]          ← reference (line metadata)
  [ProductionSchedule]  ← reference (planned targets)

KQL Database → OEE_5min Materialized View
KQL Database → Real-Time Dashboard (5 pages)
KQL Database → Activator (fault + maintenance alerts)
```

**OEE = Availability × Performance × Quality**

| Component | Per-Station Formula | Notes |
|-----------|-------------------|-------|
| Availability | Running / (Running + Fault + Maintenance) | Starved/Blocked excluded (not the station's fault) |
| Performance | ideal_cycle_time / avg(actual_cycle_time) | Only when Running |
| Quality | 1 − (rejected_parts / total_parts_processed) | Per station or end-of-line |

**Design principles:**
- The simulator sends only raw machine signals. `ideal_cycle_time` is engineering reference data stored in `StationMaster`.
- `shift` is derived from the event timestamp in KQL.
- A single Eventstream fans out to **three** KQL tables via `event_type` routing.
- Parts carry unique IDs and full station-by-station history for traceability.

---

## Production Lines

### Line-A: Precision Machining (5 stations)
Purpose: Raw bar stock → precision-machined automotive shaft

| Pos | Machine Type | Ideal Cycle (s) | Fault % | Reject % |
|-----|-------------|-----------------|---------|---------|
| 1 | CNC-Lathe | 40 | 0.5 | 2 |
| 2 | CNC-Mill | 45 | 0.8 | 3 |
| 3 | Surface-Grinder | 35 | 0.3 | 2 |
| 4 | Deburring-Station | 15 | 0.2 | 1 |
| 5 | CMM-Inspection | 60 | 0.4 | 5 |

### Line-B: Sheet Metal Forming (4 stations)
Purpose: Sheet metal → stamped/formed housing

| Pos | Machine Type | Ideal Cycle (s) | Fault % | Reject % |
|-----|-------------|-----------------|---------|---------|
| 1 | Blanking-Press | 8 | 0.6 | 2 |
| 2 | Hydraulic-Press | 12 | 1.5 | 4 |
| 3 | Trimming-Station | 10 | 0.4 | 2 |
| 4 | Quality-Inspection | 20 | 0.2 | 3 |

### Line-C: Welding & Assembly (6 stations)
Purpose: Components → welded and assembled subassembly

| Pos | Machine Type | Ideal Cycle (s) | Fault % | Reject % |
|-----|-------------|-----------------|---------|---------|
| 1 | Component-Loader | 10 | 0.1 | 0 |
| 2 | Welding-Robot | 25 | 0.7 | 3 |
| 3 | Weld-Inspection | 30 | 0.5 | 4 |
| 4 | Fastening-Station | 15 | 0.3 | 1 |
| 5 | Assembly-Robot | 20 | 0.4 | 2 |
| 6 | Leak-Test | 25 | 0.6 | 3 |

### Line-D: Surface Treatment (7 stations)
Purpose: Raw part → painted and coated finished part

| Pos | Machine Type | Ideal Cycle (s) | Fault % | Reject % |
|-----|-------------|-----------------|---------|---------|
| 1 | Surface-Prep | 20 | 0.3 | 1 |
| 2 | Chemical-Wash | 30 | 0.4 | 1 |
| 3 | Primer-Application | 25 | 0.5 | 3 |
| 4 | Paint-Booth | 40 | 0.8 | 4 |
| 5 | Curing-Oven | 90 | 0.6 | 2 |
| 6 | Coating-Inspection | 15 | 0.2 | 3 |
| 7 | Final-Packaging | 10 | 0.1 | 0 |

### Line-E: Electronics Assembly (8 stations)
Purpose: Bare PCB → tested and coated electronics module

| Pos | Machine Type | Ideal Cycle (s) | Fault % | Reject % |
|-----|-------------|-----------------|---------|---------|
| 1 | PCB-Loader | 5 | 0.1 | 0 |
| 2 | SMT-Placement | 15 | 0.6 | 3 |
| 3 | Reflow-Oven | 45 | 0.4 | 2 |
| 4 | AOI-Inspection | 10 | 0.3 | 4 |
| 5 | Through-Hole-Insert | 20 | 0.5 | 2 |
| 6 | Wave-Solder | 35 | 0.7 | 3 |
| 7 | Functional-Test | 30 | 0.3 | 5 |
| 8 | Conformal-Coat | 25 | 0.4 | 2 |

**Totals:** 5 lines, 30 machines, ~150 potential fault types, part-level tracking

### How Cascading Works

- **Station N faults** → maintenance work order created → machine enters Maintenance state
- **Downstream cascade:** Station N+1 input buffer drains → N+1 becomes Idle-Starved → N+2 → ... → line output stops
- **Upstream cascade:** Station N-1 output buffer fills → N-1 becomes Idle-Blocked → N-2 → ... → raw material intake stops
- **Recovery:** WO resolved → Station N resumes → buffers refill → cascade unwinds naturally
- Buffer capacity (default 5 parts) determines how long downstream can continue before starvation

---

## Prerequisites

- Microsoft Fabric capacity (F2 or higher) with Real-Time Intelligence enabled
- A Fabric workspace with contributor access
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) installed (to build and run the simulator)
- OR [Docker](https://docs.docker.com/get-docker/) installed (to run the pre-built container)

---

## Step 1 — Create the Eventstream

1. Open your Fabric workspace and select **+ New item → Eventstream**.
2. Name it **`manufacturing-telemetry`** and click **Create**.
3. In the Eventstream canvas, click **+ Add source → Custom endpoint**.
4. Name the source **`oee-simulator`** and click **Add**.
5. Click **Publish** (top toolbar) to save and activate the Eventstream. The **Keys** tab is only visible after the Eventstream has been published.
6. After publishing, click the **`oee-simulator`** source node on the canvas and open the **Keys** tab. Copy the **Connection string–primary key** (the full `Endpoint=sb://...;EntityPath=...` string).

---

## Step 2 — Configure and Run the Simulator

### Option A — Run with .NET (recommended for development)

1. Navigate to the simulator directory:

```bash
cd simulator/FabricOEESimulator
cp simulator.sample.yaml simulator.yaml
```

2. Open `simulator.yaml` and configure the broker with the Eventstream connection string from Step 1:

```yaml
broker:
  type: EventHub
  connection: "Endpoint=sb://<your-namespace>.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...;EntityPath=es_..."
```

3. Run the simulator:

```bash
dotnet run
```

You should see a live Spectre.Console table showing all 5 lines with 30 stations — each row shows the station's status (Running/Starved/Blocked/Fault/Maintenance), buffer levels, and parts processed.

### Option B — Run with Docker

1. Create a `simulator.yaml` file from the sample and configure as above.

2. Build and run:

```bash
cd simulator
docker build -t oee-simulator .
docker run -it --rm -v "$(pwd)/FabricOEESimulator/simulator.yaml:/app/simulator.yaml" oee-simulator
```

> **Note:** The `-it` flags are required — the simulator uses [Spectre.Console](https://spectreconsole.net/) for its interactive UI and will exit immediately without a TTY.

### Console Sink (no Fabric required)

For local testing without Fabric, leave the broker type as `Console`:

```yaml
broker:
  type: Console
```

This logs all telemetry events to the log file without sending to any external service.

### Example Event Payloads

The simulator sends three event types to the Event Hub. Each event is serialized as JSON with `null` fields omitted. Below are representative examples of each type.

**machine_telemetry** — emitted every cycle by each station:

```json
{
  "event_type": "machine_telemetry",
  "timestamp": "2025-01-15T14:32:01.4567890Z",
  "device_id": "Line-A_Stn1",
  "machine_type": "CNC-Lathe",
  "machine_status": "Running",
  "line_id": "Line-A",
  "station_position": 1,
  "actual_cycle_time": 42.3,
  "input_buffer_count": 3,
  "output_buffer_count": 1,
  "buffer_capacity": 5,
  "total_parts_processed": 847,
  "rejected_parts": 17,
  "current_part_id": "P-00042"
}
```

> When `machine_status` is `"Idle"`, an `idle_reason` field is included (e.g., `"Starved"` or `"Blocked"`). The `current_part_id` field is omitted when the station has no part loaded.

**part_event** — emitted when a part enters or exits a station:

```json
{
  "event_type": "part_event",
  "timestamp": "2025-01-15T14:32:01.8901234Z",
  "part_id": "P-00042",
  "line_id": "Line-A",
  "station_position": 1,
  "machine_type": "CNC-Lathe",
  "action": "Completed",
  "cycle_time": 42.3,
  "quality_pass": true
}
```

> The `action` field is `"Started"` when a part enters a station and `"Completed"` when it finishes. `quality_pass` is only meaningful on `"Completed"` events.

**maintenance_event** — emitted when a maintenance work order is created, started, or completed:

```json
{
  "event_type": "maintenance_event",
  "timestamp": "2025-01-15T14:35:12.3456789Z",
  "work_order_id": "WO-0019",
  "device_id": "Line-A_Stn2",
  "machine_type": "CNC-Mill",
  "line_id": "Line-A",
  "station_position": 2,
  "issue_type": "Mechanical",
  "action": "Created",
  "technician_id": "TECH-03"
}
```

> The `action` field tracks the work order lifecycle: `"Created"` → `"Started"` → `"Completed"`. The `issue_type` describes the fault category (e.g., `"Mechanical"`, `"Electrical"`, `"Calibration"`).

---

## Step 3 — Create the Eventhouse and KQL Database

1. In your Fabric workspace, select **+ New item → Eventhouse**.
2. Name it **`ManufacturingEH`** and click **Create**. A KQL Database named `ManufacturingEH` is created automatically.
3. Open the KQL Database and run the following in the **Explore your data** query window to create the tables and ingestion mappings:

```kql
// ---------------------------------------------------------------------------
// MachineEvents — periodic station telemetry (every 10s per station)
// ---------------------------------------------------------------------------
.create table MachineEvents (
    event_type:          string,
    device_id:           string,
    machine_type:        string,
    machine_status:      string,
    idle_reason:         string,
    line_id:             string,
    station_position:    int,
    actual_cycle_time:   real,
    input_buffer_count:  int,
    output_buffer_count: int,
    buffer_capacity:     int,
    total_parts_processed: long,
    rejected_parts:      long,
    current_part_id:     string,
    timestamp:           datetime
)

.create table MachineEvents ingestion json mapping 'MachineEventsMapping'
'['
'  {"column":"event_type",          "path":"$.event_type",          "datatype":"string"},'
'  {"column":"device_id",           "path":"$.device_id",           "datatype":"string"},'
'  {"column":"machine_type",        "path":"$.machine_type",        "datatype":"string"},'
'  {"column":"machine_status",      "path":"$.machine_status",      "datatype":"string"},'
'  {"column":"idle_reason",         "path":"$.idle_reason",         "datatype":"string"},'
'  {"column":"line_id",             "path":"$.line_id",             "datatype":"string"},'
'  {"column":"station_position",    "path":"$.station_position",    "datatype":"int"},'
'  {"column":"actual_cycle_time",   "path":"$.actual_cycle_time",   "datatype":"real"},'
'  {"column":"input_buffer_count",  "path":"$.input_buffer_count",  "datatype":"int"},'
'  {"column":"output_buffer_count", "path":"$.output_buffer_count", "datatype":"int"},'
'  {"column":"buffer_capacity",     "path":"$.buffer_capacity",     "datatype":"int"},'
'  {"column":"total_parts_processed","path":"$.total_parts_processed","datatype":"long"},'
'  {"column":"rejected_parts",      "path":"$.rejected_parts",      "datatype":"long"},'
'  {"column":"current_part_id",     "path":"$.current_part_id",     "datatype":"string"},'
'  {"column":"timestamp",           "path":"$.timestamp",           "datatype":"datetime"}'
']'

// ---------------------------------------------------------------------------
// PartEvents — per-part per-station transitions (entered/completed/rejected)
// ---------------------------------------------------------------------------
.create table PartEvents (
    event_type:       string,
    part_id:          string,
    line_id:          string,
    station_position: int,
    machine_type:     string,
    action:           string,
    cycle_time:       real,
    quality_pass:     bool,
    timestamp:        datetime
)

.create table PartEvents ingestion json mapping 'PartEventsMapping'
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

// ---------------------------------------------------------------------------
// MaintenanceEvents — work order lifecycle (Created/Acknowledged/InProgress/Resolved)
// ---------------------------------------------------------------------------
.create table MaintenanceEvents (
    event_type:       string,
    work_order_id:    string,
    device_id:        string,
    machine_type:     string,
    line_id:          string,
    station_position: int,
    issue_type:       string,
    action:           string,
    technician_id:    string,
    timestamp:        datetime
)

.create table MaintenanceEvents ingestion json mapping 'MaintenanceEventsMapping'
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
```

4. Create the reference data tables:

```kql
// ---------------------------------------------------------------------------
// LineMaster — production line metadata
// ---------------------------------------------------------------------------
.set-or-replace LineMaster <|
    datatable(line_id:string, line_name:string, purpose:string, station_count:int)
    [
        "Line-A", "Precision Machining",   "Raw bar stock → machined shaft",              5,
        "Line-B", "Sheet Metal Forming",    "Sheet metal → stamped housing",               4,
        "Line-C", "Welding & Assembly",     "Components → welded subassembly",             6,
        "Line-D", "Surface Treatment",      "Raw part → painted and coated finished part", 7,
        "Line-E", "Electronics Assembly",   "Bare PCB → tested electronics module",        8,
    ]

// ---------------------------------------------------------------------------
// StationMaster — per-station engineering reference data
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// ProductionSchedule — planned output targets per line/shift
// ---------------------------------------------------------------------------
.set-or-replace ProductionSchedule <|
    datatable(line_id:string, shift:string, planned_parts:long)
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
```

5. Create the materialized view for pre-aggregated OEE:

```kql
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
```

---

## Step 4 — Connect Eventstream to Eventhouse (with Routing)

All three event types (machine telemetry, part events, maintenance events) flow through the **same** Eventstream source. Use **Query** (SQL transform) operators to filter and route each `event_type` to the correct KQL table.

> **Why Query instead of Filter + Manage Fields:** The Query operator lets you write a SQL `SELECT` statement with full control over column names, types, and filtering.

### 4.1 — Route machine telemetry to MachineEvents

1. In the Eventstream canvas, from the source node click **+** and add a **Query** operation.
2. In the Query pane, click **+ Add output** and name the output **`MachineEvents`**.
3. Enter the following SQL:

```sql
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
FROM [manufacturing-telemetry-stream]
WHERE event_type = 'machine_telemetry'
```

4. Connect the `MachineEvents` output node to a **KQL Database** destination:
   - **KQL Database:** `ManufacturingEH`
   - **Table:** `MachineEvents`
   - **Input data format:** JSON

### 4.2 — Route part events to PartEvents

1. From the same source node, click **+** again to add a **second Query** operation.
2. Click **+ Add output** and name the output **`PartEvents`**.
3. Enter the following SQL:

```sql
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
FROM [manufacturing-telemetry-stream]
WHERE event_type = 'part_event'
```

4. Connect the `PartEvents` output node to a **KQL Database** destination:
   - **KQL Database:** `ManufacturingEH`
   - **Table:** `PartEvents`
   - **Input data format:** JSON

### 4.3 — Route maintenance events to MaintenanceEvents

1. Add a **third Query** operation from the source node.
2. Click **+ Add output** and name the output **`MaintenanceEvents`**.
3. Enter:

```sql
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
FROM [manufacturing-telemetry-stream]
WHERE event_type = 'maintenance_event'
```

4. Connect to **KQL Database** destination:
   - **KQL Database:** `ManufacturingEH`
   - **Table:** `MaintenanceEvents`
   - **Input data format:** JSON

### 4.4 — Publish and verify

1. Click **Publish** in the Eventstream canvas.
2. Wait ~60 seconds, then run these verification queries in the KQL Database:

```kql
// Should show 30 distinct device IDs (one per station)
MachineEvents
| summarize count() by device_id
| order by device_id asc

// Should show part events with sequential IDs per line
PartEvents
| take 20
| order by timestamp desc

// Should show maintenance work order lifecycle events
MaintenanceEvents
| take 10
| order by timestamp desc
```

> **Tip:** If a table is empty, check that the Query condition exactly matches the `event_type` string value (case-sensitive) and that all three queries are connected to destinations before publishing.

---

## Step 5 — OEE KQL Queries

These queries power the Real-Time Dashboard tiles. All queries enrich raw telemetry by joining `StationMaster` for `ideal_cycle_time` and deriving `shift` from the event timestamp.

### 5.1 — Per-Station OEE (5-minute bins)

```kql
MachineEvents
| where timestamp between (_startTime .. _endTime)
| join kind=inner StationMaster
    on $left.line_id == $right.line_id, $left.station_position == $right.station_position
| summarize
    total     = count(),
    running   = countif(machine_status == "Running"),
    downtime  = countif(machine_status in ("Fault", "Maintenance")),
    avg_actual = avgif(actual_cycle_time, machine_status == "Running"),
    ideal     = avg(ideal_cycle_time),
    parts     = sum(total_parts_processed),
    rejected  = sum(rejected_parts)
    by bin(timestamp, 5m), device_id, machine_type, line_id, station_position
| extend
    availability = iif(running + downtime > 0,
        round(todouble(running) / todouble(running + downtime), 4), real(null)),
    performance = iif(avg_actual > 0, round(ideal / avg_actual, 4), real(null)),
    quality = iif(parts > 0, round(1.0 - todouble(rejected) / todouble(parts), 4), real(null))
| extend oee = round(availability * performance * quality, 4)
| project timestamp, line_id, station_position, device_id, machine_type,
          availability, performance, quality, oee
| order by line_id asc, station_position asc, timestamp desc
```

### 5.2 — Line OEE Trend (5-minute bins)

Aggregates across all stations on a line for the overall line OEE.

```kql
let avail =
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | summarize
        running  = countif(machine_status == "Running"),
        downtime = countif(machine_status in ("Fault", "Maintenance"))
        by bin(timestamp, 5m), line_id
    | extend availability = todouble(running) / todouble(running + downtime);
let perf =
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | where machine_status == "Running"
    | join kind=inner StationMaster
        on $left.line_id == $right.line_id, $left.station_position == $right.station_position
    | summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time)
        by bin(timestamp, 5m), line_id
    | extend performance = ideal / avg_actual;
let qual =
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | where total_parts_processed > 0
    | summarize total_sum = sum(total_parts_processed), rejected_sum = sum(rejected_parts)
        by bin(timestamp, 5m), line_id
    | extend quality = 1.0 - (todouble(rejected_sum) / todouble(total_sum));
avail
| join kind=leftouter perf on timestamp, line_id
| join kind=leftouter qual on timestamp, line_id
| extend oee = round(availability * performance * quality, 4)
| project timestamp, line_id,
          availability = round(availability, 4),
          performance = round(performance, 4),
          quality = round(quality, 4), oee
| order by timestamp desc
```

### 5.3 — Live OEE Score per Line (last 5 min)

```kql
let avail =
    MachineEvents
    | where timestamp > ago(5m)
    | summarize
        running = countif(machine_status == "Running"),
        downtime = countif(machine_status in ("Fault", "Maintenance"))
        by line_id
    | extend availability = todouble(running) / todouble(running + downtime);
let perf =
    MachineEvents
    | where timestamp > ago(5m)
    | where machine_status == "Running"
    | join kind=inner StationMaster
        on $left.line_id == $right.line_id, $left.station_position == $right.station_position
    | summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time) by line_id
    | extend performance = ideal / avg_actual;
let qual =
    MachineEvents
    | where timestamp > ago(5m)
    | where total_parts_processed > 0
    | summarize total_sum = sum(total_parts_processed), rejected_sum = sum(rejected_parts) by line_id
    | extend quality = 1.0 - (todouble(rejected_sum) / todouble(total_sum));
avail
| join kind=leftouter perf on line_id
| join kind=leftouter qual on line_id
| extend oee = round(availability * performance * quality * 100, 1)
| project line_id, oee
```

### 5.4 — OEE Components Breakdown (Availability / Performance / Quality)

```kql
let avail =
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | summarize
        running = countif(machine_status == "Running"),
        downtime = countif(machine_status in ("Fault", "Maintenance"))
        by line_id
    | extend metric = "Availability",
        value = round(todouble(running)/todouble(running + downtime)*100, 1);
let perf =
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | where machine_status == "Running"
    | join kind=inner StationMaster
        on $left.line_id == $right.line_id, $left.station_position == $right.station_position
    | summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time) by line_id
    | extend metric = "Performance", value = round(ideal/avg_actual*100, 1);
let qual =
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | where total_parts_processed > 0
    | summarize total_sum = sum(total_parts_processed), rejected_sum = sum(rejected_parts) by line_id
    | extend metric = "Quality",
        value = round((1.0 - todouble(rejected_sum)/todouble(total_sum))*100, 1);
union avail, perf, qual
| project line_id, metric, value
| order by line_id asc, metric asc
```

### 5.5 — Station Status (Live Snapshot)

Most-recent status per station — includes buffer levels and idle reason.

```kql
MachineEvents
| summarize arg_max(timestamp, machine_status, idle_reason, machine_type, line_id,
    station_position, input_buffer_count, output_buffer_count, current_part_id) by device_id
| project device_id, line_id, station_position, machine_type, machine_status,
    idle_reason, input_buffer_count, output_buffer_count, current_part_id, timestamp
| order by line_id asc, station_position asc
```

### 5.6 — Fault Count by Station

```kql
MachineEvents
| where timestamp between (_startTime .. _endTime)
| where machine_status == "Fault"
| summarize fault_count = count() by device_id, machine_type, line_id, station_position
| order by fault_count desc
```

### 5.7 — Part Throughput per Line (5-min bins)

```kql
PartEvents
| where timestamp between (_startTime .. _endTime)
| where action == "completed"
| summarize parts_completed = count() by bin(timestamp, 5m), line_id
| order by timestamp desc, line_id asc
```

### 5.8 — Part Traceability (search by part_id)

Full station-by-station journey for a specific part.

```kql
PartEvents
| where part_id == _partId
| order by station_position asc
| project station_position, machine_type, action, cycle_time, quality_pass, timestamp
```

### 5.9 — Rejection Rate by Station

```kql
PartEvents
| where timestamp between (_startTime .. _endTime)
| summarize
    total = count(),
    rejected = countif(action == "rejected")
    by line_id, station_position, machine_type
| extend reject_rate = round(todouble(rejected) / todouble(total) * 100, 2)
| order by reject_rate desc
```

### 5.10 — Active Work Orders

```kql
let created =
    MaintenanceEvents
    | where timestamp > ago(24h)
    | where action == "Created"
    | summarize create_time = min(timestamp) by work_order_id, device_id, machine_type,
        line_id, station_position, issue_type;
let resolved =
    MaintenanceEvents
    | where timestamp > ago(24h)
    | where action == "Resolved"
    | summarize resolve_time = min(timestamp) by work_order_id;
created
| join kind=leftouter resolved on work_order_id
| where isnull(resolve_time)
| extend open_minutes = datetime_diff('minute', now(), create_time)
| project work_order_id, device_id, machine_type, line_id, station_position,
    issue_type, create_time, open_minutes
| order by open_minutes desc
```

### 5.11 — MTTR by Machine Type

```kql
let wo_created =
    MaintenanceEvents
    | where timestamp > ago(24h)
    | where action == "Created"
    | project work_order_id, create_time = timestamp, machine_type, line_id;
let wo_resolved =
    MaintenanceEvents
    | where timestamp > ago(24h)
    | where action == "Resolved"
    | project work_order_id, resolve_time = timestamp;
wo_created
| join kind=inner wo_resolved on work_order_id
| extend mttr_minutes = datetime_diff('minute', resolve_time, create_time)
| where mttr_minutes > 0
| summarize avg_mttr = round(avg(todouble(mttr_minutes)), 1), incidents = count()
    by machine_type, line_id
| join kind=leftouter StationMaster
    on $left.line_id == $right.line_id, $left.machine_type == $right.machine_type
| project machine_type, manufacturer, line_id, avg_mttr, incidents
| order by avg_mttr desc
```

### 5.12 — Fault Type Pareto

```kql
MaintenanceEvents
| where timestamp > ago(24h)
| where action == "Created"
| summarize fault_count = count() by issue_type, machine_type
| order by fault_count desc
```

### 5.13 — Shift KPI Summary

```kql
MachineEvents
| where timestamp > ago(8h)
| where total_parts_processed > 0
| extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
| summarize
    total_p    = sum(total_parts_processed),
    rejected_p = sum(rejected_parts),
    faults     = countif(machine_status == "Fault")
    by shift, line_id
| extend quality = round(1.0 - (todouble(rejected_p) / todouble(total_p)), 4)
| project shift, line_id, total_p, rejected_p, quality, faults
| order by line_id asc, shift asc
```

### 5.14 — Schedule Adherence

```kql
MachineEvents
| where timestamp > ago(8h)
| extend shift = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
| summarize device_total = max(total_parts_processed) by line_id, shift, device_id
| summarize actual_parts = sum(device_total) by line_id, shift
| join kind=inner ProductionSchedule on line_id, shift
| extend adherence_pct = round(todouble(actual_parts) / todouble(planned_parts) * 100, 1)
| project line_id, shift, actual_parts, planned_parts, adherence_pct
| order by line_id asc, shift asc
```

### 5.15 — Buffer Health (cascade detection)

Detects stations that are currently starved or blocked — indicates a cascade in progress.

```kql
MachineEvents
| summarize arg_max(timestamp, machine_status, idle_reason, input_buffer_count,
    output_buffer_count, buffer_capacity) by device_id, line_id, station_position, machine_type
| where machine_status == "Idle"
| project device_id, line_id, station_position, machine_type, idle_reason,
    input_buffer_count, output_buffer_count, buffer_capacity, timestamp
| order by line_id asc, station_position asc
```

### 5.16 — OEE Loss Waterfall

```kql
let avail_v = materialize(
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | summarize
        running = countif(machine_status == "Running"),
        downtime = countif(machine_status in ("Fault", "Maintenance"))
    | extend v = round(todouble(running) / todouble(running + downtime) * 100, 2));
let perf_v = materialize(
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | where machine_status == "Running"
    | join kind=inner StationMaster
        on $left.line_id == $right.line_id, $left.station_position == $right.station_position
    | summarize ideal = avg(ideal_cycle_time), actual = avg(actual_cycle_time)
    | extend v = round(ideal / actual * 100, 2));
let qual_v = materialize(
    MachineEvents
    | where timestamp between (_startTime .. _endTime)
    | where total_parts_processed > 0
    | summarize tp = sum(total_parts_processed), rp = sum(rejected_parts)
    | extend v = round((1.0 - todouble(rp) / todouble(tp)) * 100, 2));
let a = toscalar(avail_v | project v);
let p = toscalar(perf_v  | project v);
let q = toscalar(qual_v  | project v);
union
    (print stage="1 - Theoretical Max",     value=100.0),
    (print stage="2 - After Availability",  value=a),
    (print stage="3 - After Performance",   value=round(a * p / 100.0, 2)),
    (print stage="4 - OEE (after Quality)", value=round(a * p * q / 10000.0, 2))
```

### 5.17 — Using the Materialized View

Once the `OEE_5min` materialized view is created, query it for better performance:

```kql
OEE_5min
| where timestamp between (_startTime .. _endTime)
| extend
    availability = iif(running + fault + maintenance > 0,
        todouble(running) / todouble(running + fault + maintenance), real(null)),
    performance  = iif(avg_actual > 0, ideal / avg_actual, real(null)),
    quality      = iif(total_parts > 0, 1.0 - todouble(rejected) / todouble(total_parts), real(null))
| extend oee = round(availability * performance * quality, 4)
| project timestamp, device_id, machine_type, line_id, station_position, shift,
          availability = round(availability, 4),
          performance  = round(performance, 4),
          quality      = round(quality, 4), oee
| order by timestamp desc
```

### 5.18 — Machine Status Distribution (Last Hour)
Visual Type: **Pie Chart**

```kql
MachineEvents
| where timestamp between (_startTime .. _endTime)
| summarize Count = count() by machine_status
```

### 5.19 — Completed vs Rejected per Line
Visual Type: **Column Chart**

```kql
PartEvents
| where timestamp between (_startTime .. _endTime)
| summarize Completed = countif(action == 'completed'), Rejected = countif(action == 'rejected') by line_id
| order by line_id asc
```

### 5.20 — Factory Active Operations
Visual Type: **Multi Stat**

```kql
MachineEvents
| where timestamp between (_startTime .. _endTime)
| summarize Operations = count()
```

### 5.21 — Overall Factory OEE Gauge
Visual Type: **Plotly**

```kql
let avail = MachineEvents
| where timestamp between (_startTime .. _endTime)
| summarize running = countif(machine_status == "Running"), downtime = countif(machine_status in ("Fault", "Maintenance"))
| extend availability = coalesce(todouble(running) / todouble(running + downtime), 0.0);
let perf = MachineEvents
| where timestamp between (_startTime .. _endTime)
| where machine_status == "Running"
| join kind=inner StationMaster on line_id, station_position
| summarize avg_actual = avg(actual_cycle_time), ideal = avg(ideal_cycle_time)
| extend performance = min_of(coalesce(ideal / avg_actual, 0.0), 1.0);
let qual = PartEvents
| where timestamp between(_startTime .. _endTime)
| where action in ("completed", "rejected")
| summarize total_sum = count(), rejected_sum = countif(action == "rejected")
| extend quality = coalesce(1.0 - (todouble(rejected_sum) / todouble(total_sum)), 1.0);
let overallOEE = toscalar(avail | extend dummy=1
| join kind=inner (perf | extend dummy=1) on dummy
| join kind=inner (qual | extend dummy=1) on dummy
| extend oee = availability * performance * quality
| project oee=oee*100);
print plotly=dynamic({"data": [{"type": "indicator", "mode": "gauge+number", "value": 0, "title": {"text": "Overall OEE %"}, "gauge": {"axis": { "range": [null, 100] }, "steps": [ { "range": [0, 60], "color": "red" }, { "range": [60, 80], "color": "yellow" }, { "range": [80, 100], "color": "green" } ], "threshold": { "line": { "color": "black", "width": 4 }, "thickness": 0.75, "value": 0 }}}]}) 
| extend plotly = bag_set_key(plotly, "data[0].value", overallOEE)
| extend plotly = bag_set_key(plotly, "data[0].gauge.threshold.value", overallOEE)
```

### 5.22 — Factory KPIs (5-min snapshot)
Visual Type: **Multi Stat**

```kql
let total_p = toscalar(MachineEvents | where timestamp > ago(5m) | summarize sum(total_parts_processed));
let rejected_p = toscalar(MachineEvents | where timestamp > ago(5m) | summarize sum(rejected_parts));
let fault_c = toscalar(MachineEvents | where timestamp > ago(5m) | where machine_status == "Fault" | count);
let running_c = toscalar(MachineEvents | where timestamp > ago(5m) | where machine_status == "Running" | count);
let downtime_c = toscalar(MachineEvents | where timestamp > ago(5m) | where machine_status in ("Fault", "Maintenance") | count);
let uptime = round(todouble(running_c) / todouble(running_c + downtime_c) * 100, 1);
let quality = round((1.0 - todouble(rejected_p) / todouble(total_p)) * 100, 1);
union
    (print metric = "Uptime %", value = uptime),
    (print metric = "Quality %", value = quality),
    (print metric = "Total Parts", value = todouble(total_p)),
    (print metric = "Active Faults", value = todouble(fault_c))
```

### 5.23 — Parts Funnel (Entered → Passed → Rejected)
Visual Type: **Funnel**

```kql
let data = PartEvents
| where timestamp between (_startTime .. _endTime)
| where action in ("completed", "rejected")
| summarize
    total_entered = count(),
    passed_qc = countif(action == "completed"),
    rejected = countif(action == "rejected");
data | project stage = "1 - Total Entered", value = total_entered
| union (data | project stage = "2 - Passed QC", value = passed_qc)
| union (data | project stage = "3 - Rejected", value = rejected)
| order by stage asc
```

### 5.24 — Factory Snapshot (Card)
Visual Type: **Card**

```kql
let total_p = toscalar(PartEvents | where timestamp between (_startTime .. _endTime) | where action == "completed" | count);
let rejected_p = toscalar(PartEvents | where timestamp between (_startTime .. _endTime) | where action == "rejected" | count);
let running_c = toscalar(MachineEvents | where timestamp between (_startTime .. _endTime) | where machine_status == "Running" | count);
let fault_c = toscalar(MachineEvents | where timestamp between (_startTime .. _endTime) | where machine_status == "Fault" | count);
print Total_Parts_Produced = total_p, Rejected = rejected_p, Running_Stations = running_c, Active_Faults = fault_c
```

### 5.25 — Average Cycle Time (Time Series)
Visual Type: **Timechart**

```kql
MachineEvents
| where timestamp between (_startTime .. _endTime)
| where machine_status == "Running"
| summarize avg_cycle = round(avg(actual_cycle_time), 2) by bin(timestamp, 5m), line_id
| order by timestamp asc
```

### 5.26 — Total Parts Produced
Visual Type: **Multi Stat**

```kql
let total_p = toscalar(PartEvents | where timestamp between (_startTime .. _endTime) | where action == "completed" | count);
print Metric = "Parts Produced", Value = total_p
```

> **Note:** Sections 5.18–5.26 showcase additional visual types (pie, column, funnel, card, multistat, timechart, plotly) distributed across the stakeholder pages.

---

## Step 6 — Build the Real-Time Dashboard

There are two ways to create the dashboard:

- **Option A — Build it manually** by adding each tile. Best for learning.
- **Option B — Import the pre-built template** from `oee-dashboard.template.json`.

### Option A — Manual Dashboard Build

1. In your Fabric workspace, select **+ New item → Real-Time Dashboard**.
2. Name it **`OEE Manufacturing Dashboard`** and click **Create**.
3. Click **+ Add data source → KQL Database** and select `ManufacturingEH`.

#### Page 1: Corporate Executive

High-level KPIs and trends — the "how's the factory doing?" view.

| Tile | Visualization | Query | Key Settings |
|------|--------------|-------|-------------|
| Factory OEE Gauge | Plotly | 5.21 | Gauge indicator with red/yellow/green bands |
| Factory Snapshot | Card | 5.24 | Parts produced, rejected, running stations, faults |
| Live OEE (last 5 min) | Multi Stat | 5.3 | OEE per line, Green≥80/Yellow≥60/Red<60 |
| Machine Status Distribution | Pie | 5.18 | Category: machine_status |
| Line OEE Trend | Line chart | 5.2 | X: timestamp, Y: oee, Series: line_id |
| OEE Loss Waterfall | Bar | 5.16 | X: stage, Y: value |

#### Page 2: Plant Manager

Cross-line comparison, maintenance health, and scheduling.

| Tile | Visualization | Query | Key Settings |
|------|--------------|-------|-------------|
| OEE Components (A × P × Q) | Bar | 5.4 | X: metric, Y: value, Series: line_id |
| Part Throughput per Line | Area chart | 5.7 | X: timestamp, Y: parts_completed, Series: line_id |
| Completed vs Rejected by Line | Column | 5.19 | X: line_id, Y: Completed/Rejected |
| Fault Type Pareto | Bar | 5.12 | X: issue_type, Y: fault_count |
| MTTR by Machine Type | Bar | 5.11 | X: machine_type, Y: avg_mttr |
| Shift KPI Summary | Table | 5.13 | Shift performance comparison |
| Schedule Adherence | Table | 5.14 | Target vs actual comparison |

#### Page 3: Line Manager

Deep-dive into a specific line's stations and flow. The `Line ID` parameter (`_lineId`, default `Line-A`) is shown on this page to filter tiles.

| Tile | Visualization | Query | Key Settings |
|------|--------------|-------|-------------|
| Per-Station OEE | Bar | 5.1 (filtered by `_lineId`) | X: station_position, Y: oee |
| Parts Funnel (Entered > Passed > Rejected) | Funnel | 5.23 | Entered → Passed QC → Rejected |
| Station Pipeline | Table | 5.5 (filtered by `_lineId`) | Ordered stations, buffers, status |
| Cascade Alert (Starved/Blocked) | Table | 5.15 (filtered by `_lineId`) | Bottleneck detection |
| Actual vs Ideal Cycle Time | Bar | Station cycle time comparison (filtered by `_lineId`) | X: machine_type, Y: cycle_time |
| Parts Funnel by Station | Bar | Station-level funnel (filtered by `_lineId`) | X: station, Y: count |
| Quality Trend | Line chart | Quality over time | X: timestamp, Y: quality_pct, Series: line_id |

#### Page 4: Maintenance Technician

Equipment health, work orders, and fault diagnosis.

| Tile | Visualization | Query | Key Settings |
|------|--------------|-------|-------------|
| Open Work Orders | Table | 5.10 | Sorted by open_minutes desc |
| Work Order Lifecycle | Table | WO Lifecycle query below | Created → Ack → Resolve timeline |
| Equipment Age vs OEE | Scatter | Equipment Age query below | X: machine_type, Y: oee, Color: manufacturer |
| Faults by Station | Bar | 5.6 | X: device_id, Y: fault_count |
| Fault Distribution Treemap | Bar | Fault breakdown | X: issue_type, Y: count |
| Station Availability Heatmap | Heatmap | Availability patterns | X: timestamp, Y: station, Value: availability |
| Cycle Time Anomaly Detection | Anomaly chart | Anomaly detection | X: timestamp, Y: cycle_time |

#### Page 5: Quality / Station Worker

Part-level data, rejection details, and traceability. The `Part ID` parameter (`_partId`) is shown on this page for part traceability lookup.

| Tile | Visualization | Query | Key Settings |
|------|--------------|-------|-------------|
| Station Status (Live) | Table | 5.5 | Current station state (all lines) |
| Total Parts Produced | Multi Stat | 5.26 | Output count metric |
| Rejection Rate by Station | Bar | 5.9 | X: machine_type, Y: reject_rate |
| Avg Cycle Time (Time Series) | Time chart | 5.25 | X: timestamp, Y: avg_cycle, Series: line_id |
| Part Journey (Traceability) | Table | 5.8 with _partId param | Station-by-station tracking |
| Factory KPIs (5 min) | Multi Stat | 5.22 | Uptime %, Quality %, Total Parts, Active Faults |

### Dashboard Auto-Refresh

Set the dashboard auto-refresh to **30 seconds** via **Dashboard settings → Auto refresh → 30s**.

### Option B — Import the Pre-Built Template

1. Copy the template to create your dashboard file:
   ```bash
   cp oee-dashboard.template.json oee-dashboard.json
   ```

2. Replace the placeholders in `oee-dashboard.json`:
   - `__CLUSTER_URI__` — the Eventhouse Query URI (found on the Eventhouse overview page)
   - `__DATABASE_ID__` — the KQL Database ID (found on the database overview page under Properties)

3. In the Fabric workspace: **+ New item → Import from file → Real-Time Dashboard** → upload `oee-dashboard.json`.

---

## Step 7 — Configure Activator Alerts (Optional)

1. In the Eventstream canvas, click **+ Add destination → Activator**.
2. Name it **`MachineAlerts`**.
3. Add a **Fault alert rule**: trigger when `machine_status == 'Fault'`, grouped by `device_id`.
4. Add a **Low OEE KQL rule**: query `OEE_5min` where `oee < 0.60`.
5. Configure notification actions (email, Teams, etc.).

---

## Automated Setup (Alternative to Steps 1–6)

Instead of following the manual steps, you can run the automated provisioner script:

```bash
bash completed_tutorial_build.sh --workspace-name "My Workspace"
# -- or with device code auth --
bash completed_tutorial_build.sh --workspace-name "My Workspace" --use-device-code
```

This script creates the Eventhouse, KQL Database, tables, reference data, materialized view, Eventstream with routing, and imports the dashboard — all via the Fabric REST API.

> **⚠ Important:** After the script completes, open the Eventstream in the Fabric UI and verify it shows **Running**. The Eventstream sometimes does not start automatically after provisioning. If it is stopped or in draft state, click **Publish** to activate it. Data will not flow to the KQL tables until the Eventstream is running.

---

## Appendix — Troubleshooting

| Symptom | Check |
|---------|-------|
| Simulator exits immediately | Run with `-it` flags for Docker; ensure `simulator.yaml` exists |
| Eventstream not running after script | Open the Eventstream in the Fabric UI and click **Publish** — it sometimes does not start automatically |
| No rows in `MachineEvents` | Confirm Eventstream is running and destination is published; check ingestion mapping name matches |
| No rows in `PartEvents` | Verify the third Query operator for `part_event` is connected and published |
| OEE values > 1.0 | Performance can exceed 1.0 if actual cycle time < ideal — this is valid |
| All stations show "Starved" | Normal at startup — first part needs to traverse the full line before output appears |
| 0 parts produced in short runs | Lines take 50–250 seconds of wall clock before the first part exits |
| Activator not firing | Verify Eventstream destination for Activator is published; check rule condition |
| Dashboard tiles show "No data" | Extend the time range — if the simulator just started, use `ago(5m)` |
