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
- **Option B — Import the pre-built template** from `dashboard/oee-dashboard.template.json`.

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
   cp dashboard/oee-dashboard.template.json dashboard/oee-dashboard.json
   ```

2. Replace the placeholders in `dashboard/oee-dashboard.json`:
   - `__CLUSTER_URI__` — the Eventhouse Query URI (found on the Eventhouse overview page)
   - `__DATABASE_ID__` — the KQL Database ID (found on the database overview page under Properties)

3. In the Fabric workspace: **+ New item → Import from file → Real-Time Dashboard** → upload `dashboard/oee-dashboard.json`.

---

## Step 7 — Configure Activator Alerts (Optional)

1. In the Eventstream canvas, click **+ Add destination → Activator**.
2. Name it **`MachineAlerts`**.
3. Add a **Fault alert rule**: trigger when `machine_status == 'Fault'`, grouped by `device_id`.
4. Add a **Low OEE KQL rule**: query `OEE_5min` where `oee < 0.60`.
5. Configure notification actions (email, Teams, etc.).

---

## Step 8 — Create the Ontology for Data Agent Queries (Optional)

Create a Fabric Ontology to enable natural language querying via Data Agent (Copilot). The ontology defines the semantic relationships between production lines, stations, and events.

### 8.1 — Enable OneLake Availability on KQL Database

**Critical prerequisite**: Ontologies require OneLake availability to index KQL tables into the knowledge graph.

1. Open the **ManufacturingEH** KQL Database in the Fabric portal.
2. Navigate to **Settings → Database details → OneLake availability**.
3. Enable **OneLake folder** and click **Done**.
4. Wait 2-3 minutes for the setting to propagate.

### 8.2 — Upload Ontology CSV Files

1. Open the **ManufacturingLH** lakehouse in the Fabric portal.
2. Navigate to **Files** and create a folder named `ontology`.
3. Upload the following CSV files from the `ontology/` directory in this repo:
   - `definition/entity_types.csv` (6 entity types, 48 properties)
   - `definition/relationship_types.csv` (8 relationships)
   - `binding/binding_entity_types.csv` (51 bindings: 27 static + 24 timeseries)
   - `binding/binding_relationship_types.csv` (8 relationship bindings)

4. Download the latest `fabriciq_ontology_accelerator` wheel from the [FabricIQ Accelerator releases](https://github.com/microsoft/fabriciq-accelerator/releases) and upload it to the `Files/ontology/` folder.

### 8.3 — Run the Ontology Creation Notebook

1. Open the `notebooks/create_ontology.ipynb` notebook in VS Code (requires Fabric extension) or upload it to the Fabric workspace.
2. Attach the notebook to the **ManufacturingLH** lakehouse.
3. Run all cells sequentially:
   - **Step 1**: Installs the Fabric IQ Ontology Accelerator
   - **Step 2**: Gets workspace context (Eventhouse ID, Lakehouse ID, cluster URI)
   - **Step 3**: Verifies CSV files exist
   - **Step 3b**: Validates CSV internal consistency (catches 5 common failure modes)
   - **Step 4**: Creates the `.iq` package (ZIP file)
   - **Step 5**: Generates ontology definition with binding substitutions
   - **Step 6**: Creates the ontology via Fabric REST API
   - **Step 7**: Verifies the GraphModel provisions successfully
   - **Step 7b**: Diagnoses type mismatches if the graph is empty

### 8.4 — Ontology Architecture

| Entity Type | Properties | Description | Binding Strategy |
|-------------|-----------|-------------|------------------|
| **ProductionLine** | line_id (ID), line_name, purpose, station_count | Factory floor lines | Static (lakehouse) |
| **Station** | line_id + station_position (composite ID), machine_type, ideal_cycle_time, manufacturer, install_year, buffer_capacity | Individual machines | Static (lakehouse) |
| **ProductionSchedule** | line_id + shift (composite ID), planned_parts | Shift-level targets | Static (lakehouse) |
| **MachineEvent** | device_id (ID), timestamp, event_type, machine_status, idle_reason, actual_cycle_time, buffer counts, parts processed | Machine telemetry | Hybrid (identifiers via lakehouse, telemetry via KQL) |
| **PartEvent** | part_id (ID), timestamp, event_type, action, cycle_time, quality_pass | Part lifecycle | Hybrid (identifiers via lakehouse, telemetry via KQL) |
| **MaintenanceEvent** | work_order_id (ID), timestamp, event_type, device_id, issue_type, action, technician_id | Work order lifecycle | Hybrid (identifiers via lakehouse, telemetry via KQL) |

**Relationships** (8):
- Station → ProductionLine (via line_id FK)
- ProductionSchedule → ProductionLine (via line_id FK)
- MachineEvent → ProductionLine (via line_id FK)
- MachineEvent → Station (via line_id + station_position composite FK)
- PartEvent → ProductionLine (via line_id FK)
- PartEvent → Station (via line_id + station_position composite FK)
- MaintenanceEvent → ProductionLine (via line_id FK)
- MaintenanceEvent → Station (via line_id + station_position composite FK)

### 8.5 — Key Design Decisions

**Why OEEMetric is excluded:**
- OEE_5min is a KQL **materialized view** (not a base table)
- Materialized views **don't replicate to OneLake** → can't be accessed via lakehouse `dbo` schema
- NonTimeSeries bindings require lakehouse table access → OEEMetric would fail silently
- Solution: Query OEE data directly via KQL (TimeSeries) or create a separate Delta table copy

**Hybrid binding strategy:**
- **NonTimeSeries bindings** (graph indexing): Static properties (identifiers, FK columns, display names) → lakehouse tables via OneLake availability
- **TimeSeries bindings** (real-time lookup): Telemetry properties (timestamp, metrics, status) → KQL tables directly
- Identifiers appear in **both** binding types to enable graph joins AND time-series queries

**Validation approach:**
- The notebook includes a validation cell (Step 3b) that checks CSV consistency **before** deployment
- The diagnostic cell (Step 7b) compares declared CSV types against actual table schemas to catch silent failures caused by type mismatches
- Based on lessons from FabricOracleHFMDemo: Fabric silently drops entities when PropertyDataType doesn't match the actual Spark/Delta column type

### 8.6 — Query the Ontology with Data Agent

Once the ontology is created, connect a Data Agent to ask natural language questions:

**Example queries:**
- "What is the current status of all stations on Line-A?"
- "Which stations have the highest fault rates this week?"
- "Show maintenance events for Line-C station 2 in the last 24 hours"
- "List all production lines with their station counts"
- "What parts were processed by Line-B today?"

---

## Step 9 — Provision the Foundry Resource and Deploy Models (Optional)

Adds the **agent runtime** pillar. The Microsoft Foundry resource + project hosts the chat model that powers the agent and exposes the OpenAI endpoint that Azure AI Search uses to generate embeddings for the SOP corpus in Step 10.

**Run Step 9 before Step 10** — the AI Search indexer needs the OpenAI endpoint produced by the embedding-model deployment in 9.3.

This step uses the current Microsoft Foundry resource model (`AIServices` kind with project management enabled). For the underlying CLI commands, see the [Microsoft Foundry quickstart](https://learn.microsoft.com/azure/foundry/tutorials/quickstart-create-foundry-resources?tabs=azurecli).

> Prefer the scripted path? See [QUICKSTART.md §6](QUICKSTART.md#6-optional-provision-the-foundry-resource-and-deploy-models).

### 9.1 — Create the Foundry resource and project

1. Open the [Microsoft Foundry portal](https://ai.azure.com) and sign in.
2. Click **+ Create new** → **Foundry resource** (or **Microsoft Foundry resource**).
3. Fill in:
   - **Foundry resource name:** `oee-foundry` (or your preferred name).
   - **Subscription / Resource group:** your Azure subscription and a new or existing resource group.
   - **Region:** a region that has both `gpt-4.1` and `text-embedding-3-large` quota (e.g., `eastus2` or `westus3`).
   - **Custom subdomain:** accept the default (`oee-foundry`) — it must be globally unique. This determines your OpenAI endpoint URL.
   - Accept the default networking and identity options unless you have a corporate requirement.
4. Click **Create**. Provisioning takes 2–3 minutes.
5. Inside the new resource, click **+ Create project** and name it `oee-factory-iq`.
6. After the project is created, open **Project overview** and copy its **resource ID** and **endpoint URL** — you reference both later when registering knowledge sources.

### 9.2 — Deploy the chat model

In the Foundry portal → **Project `oee-factory-iq`** → **Models + endpoints** → **+ Deploy model** → **Deploy base model**:

1. **Model:** `gpt-4.1` (or your preferred chat model).
2. **Deployment name:** `gpt-4.1`.
3. **Model version:** `2025-04-14` (or the latest available).
4. **Deployment type:** `Standard`.
5. **Capacity:** 50K TPM (or your quota allocation).
6. Click **Deploy**.

Wait for status **Succeeded** before continuing.

### 9.3 — Deploy the embedding model

Still on the **Models + endpoints** page → **+ Deploy model** → **Deploy base model**:

1. **Model:** `text-embedding-3-large`.
2. **Deployment name:** `text-embedding-3-large`.
3. **Model version:** `1` (or the latest available).
4. **Deployment type:** `Standard`.
5. **Capacity:** 50K TPM minimum (one indexer run against the 36 PDFs consumes ~3M tokens).
6. Click **Deploy**.

After the status is **Succeeded**, open the Foundry resource (not the project) → **Keys and Endpoint** and copy the **Azure OpenAI endpoint** (looks like `https://<custom-subdomain>.openai.azure.com`). This is the **OpenAI endpoint URL** you reference in Step 10 when configuring the AI Search indexer.

---

## Step 10 — Index the SOP Corpus in Azure AI Search (Optional)

Adds the **static knowledge** pillar — 36 standard-operating-procedure PDFs (one per station + 6 cross-cutting policy documents) indexed with hybrid (keyword + vector + semantic) search. The Foundry agent in Step 11 will use this as its second knowledge source alongside the Fabric Data Agent.

**What you get:** an Azure AI Search index named `oee-sops` that exposes per-page chunks with fields `id`, `parent_id`, `metadata_storage_name`, `line_id`, `station_position`, `chunk`, and `vector`. Filter by `line_id eq 'Line-D' and station_position eq '05'` to ground answers in a specific station's SOP, or drop the filter to surface cross-cutting policy.

> Prefer the scripted path? See [QUICKSTART.md §7](QUICKSTART.md#7-optional-index-the-sop-corpus-in-azure-ai-search).

### 10.1 — (Developer-only) Regenerate the PDFs

The 36 PDFs are already committed under `knowledge/*.pdf`. Skip to 10.2 unless you have authored a new SOP or modified a markdown source in `knowledge/source/`.

If you do need to rebuild, install `pandoc` plus either `wkhtmltopdf` (default) or `xelatex`, then run `bash scripts/build-sops.sh`. See [knowledge/README.md](knowledge/README.md) for the filename convention and source-of-truth rules.

### 10.2 — Create a storage account and upload the PDFs

1. In the [Azure portal](https://portal.azure.com), create or choose a **storage account** in the same region as your Foundry resource.
   - Performance: **Standard**. Redundancy: **LRS** is fine for the demo.
2. Open the storage account → **Containers** → **+ Container**. Name it **`oee-sops`** and leave the access level at **Private**.
3. Open the new container → **Upload** → drag all 36 files from your local `knowledge/*.pdf` folder and upload them.

You should end up with 36 PDF blobs whose names follow the convention `Line-X_NN_<StationName>_SOP.pdf` (per-station) or `<Topic>.pdf` (cross-cutting). The line and station tokens in the filename are what drive filtering later.

### 10.3 — Create the Azure AI Search service

1. In the Azure portal, **+ Create a resource** → **Azure AI Search**.
2. Choose the same subscription and resource group; **Service name** must be globally unique (e.g., `oee-search-<initials>`).
3. **Location:** same region as your Foundry resource and storage account.
4. **Pricing tier:** **Standard (S1)** — required for vector and semantic search at the scale needed by this index.
5. Click **Review + create**, then **Create**. Provisioning takes 2–3 minutes.
6. Once deployed, open the service → **Semantic ranker** → enable the **Free** plan (sufficient for the demo).

### 10.4 — Run the Import-and-Vectorize-Data wizard

The portal wizard handles the bulk of the index, skillset, and indexer creation:

1. Open the AI Search service → **Overview** → **Import and vectorize data**.
2. **Data source:** **Azure Blob Storage**.
   - Choose your storage account and the **`oee-sops`** container.
   - Authentication: managed identity is cleanest; access key works too.
3. **Vectorize your text:**
   - **Kind:** **Azure OpenAI**.
   - **AI service:** the Foundry AOAI endpoint from Step 9.3.
   - **Model deployment:** `text-embedding-3-large`.
   - **Authentication:** **API key** (paste a key from the Foundry portal → Project → Keys + endpoints).
4. **Vectorize and enrich your images:** leave unchecked (the SOPs are text-only).
5. **Advanced settings:**
   - **Chunk length (characters):** `2000`.
   - **Page overlap length:** `200`.
6. **Objects name:** prefix `oee-sops`. The wizard will create:
   - Index: `oee-sops`.
   - Indexer: `oee-sops-indexer`.
   - Skillset: `oee-sops-skillset`.
   - Data source: `oee-sops-datasource`.
7. Click **Create**. The wizard provisions everything and starts the indexer.

Wait for the indexer's first run to finish (5–10 minutes for 36 PDFs).

### 10.5 — Add `line_id` and `station_position` filterable fields

The wizard creates the index but does not extract `line_id` / `station_position` from the filename. Add them by editing the index and indexer JSON.

1. Open AI Search → **Indexes** → **`oee-sops`** → **Edit JSON**. Add these two fields to the `fields` array (keep the existing wizard-generated fields untouched):

   ```json
   { "name": "line_id",           "type": "Edm.String", "filterable": true, "facetable": true, "searchable": false, "retrievable": true },
   { "name": "station_position",  "type": "Edm.String", "filterable": true, "facetable": true, "searchable": false, "retrievable": true }
   ```

   Click **Save**.

2. Open AI Search → **Indexers** → **`oee-sops-indexer`** → **Indexer definition (JSON)**. In the `fieldMappings` array (add it if missing), append:

   ```json
   {
     "sourceFieldName": "metadata_storage_name",
     "targetFieldName": "line_id",
     "mappingFunction": { "name": "extractTokenAtPosition", "parameters": { "delimiter": "_", "position": 0 } }
   },
   {
     "sourceFieldName": "metadata_storage_name",
     "targetFieldName": "station_position",
     "mappingFunction": { "name": "extractTokenAtPosition", "parameters": { "delimiter": "_", "position": 1 } }
   }
   ```

   Click **Save**.

3. Open the indexer → **Reset** → confirm → **Run**. The reset re-emits every document so the new mappings populate the new fields. Wait for the run to complete.

### 10.6 — Confirm the semantic configuration

1. AI Search → **Indexes** → **`oee-sops`** → **Semantic configurations**.
2. The wizard creates one named `oee-sops-semantic-configuration`. Rename it to **`oee-semantic`** (or recreate it under that name) so it matches the value the Foundry agent expects.
3. Confirm the configuration prioritises the `chunk` field as the content field and `metadata_storage_name` as the title.

### 10.7 — Verify the index

Open the index → **Search explorer** and run:

```json
{
  "search": "Pressure-Loss corrective action",
  "queryType": "semantic",
  "semanticConfiguration": "oee-semantic",
  "filter": "line_id eq 'Line-B' and station_position eq '02'",
  "select": "metadata_storage_name,line_id,station_position,chunk",
  "top": 3
}
```

You should see `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf` chunks containing section 4.1. Repeat with `"search": "Curing-Oven temperature drift"` and no filter — the top hit should be `Line-D_05_Curing-Oven_SOP.pdf`.

### 10.8 — Capture the values for Step 11

Before moving on, record these — Step 11.2 needs all of them:

| Value | Where to find it |
|---|---|
| **Search endpoint** | AI Search → **Overview** → **URL** (looks like `https://<service>.search.windows.net`). |
| **Query key** | AI Search → **Keys** → **Manage query keys** → use the read-only key. **Do not** use the admin key. |
| **Index name** | `oee-sops` (or whatever you chose). |
| **Embedding model** | `text-embedding-3-large` (must match the deployment in Step 9.3). |
| **Semantic configuration** | `oee-semantic`. |

### 10.9 — Pipeline reference

| Step | Component | Notes |
|---|---|---|
| 1 | **Blob source** | Container `oee-sops` with 36 PDFs. |
| 2 | **DocumentExtractionSkill** | Extracts text and metadata from each PDF. |
| 3 | **SplitSkill** | Chunks pages (2000 chars, 200 overlap). |
| 4 | **AzureOpenAIEmbeddingSkill** | Generates 3072-dim vectors via `text-embedding-3-large`. |
| 5 | **Index projection** | One Search document per chunk, parent linked by `parent_id`. |
| 6 | **Field mappings** | `line_id` and `station_position` extracted from `metadata_storage_name` by `extractTokenAtPosition` (underscore-delimited). |

---

## Step 11 — Build the Agent and Attach Knowledge Tools (Optional)

Wires both knowledge sources behind a single Foundry agent that handles 5 personas (Corp Exec, Plant Manager, Line Manager, Maintenance Tech, Quality Worker). Routing is configured in the system prompt: live questions → Fabric Data Agent; procedure / policy → AI Search; combined → both.

> **Why this section was rewritten.** The Microsoft Foundry portal moved from the legacy global *Foundry IQ → Knowledge* registry to a per-agent **Knowledge** panel under the Foundry Agent Service. Classic agents are deprecated and will be retired on **March 31, 2027** — this tutorial targets the current GA flow. References: [Foundry Agent Service overview](https://learn.microsoft.com/azure/foundry/agents/overview), [Azure AI Search tool](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/ai-search), [Fabric data agent in Foundry](https://learn.microsoft.com/fabric/data-science/data-agent-foundry).

This step is entirely manual in the Foundry portal today. All values you need came from Steps 9 and 10.

### 11.1 — Grant the Foundry project access to AI Search

The Foundry project's system-assigned managed identity needs to read the `oee-sops` index. From a terminal:

```bash
FOUNDRY_RG="iotopsrg"
FOUNDRY_NAME="iotopsfoundry"
SEARCH_NAME="<your-ai-search-service-name>"   # from Step 10
SEARCH_RG="iotopssearch"                       # from Step 10

# Get the Foundry account's MI principal ID
FOUNDRY_PRINCIPAL=$(az cognitiveservices account show \
  -g "$FOUNDRY_RG" -n "$FOUNDRY_NAME" \
  --query identity.principalId -o tsv)

# Search service resource ID
SEARCH_ID=$(az search service show \
  -g "$SEARCH_RG" --name "$SEARCH_NAME" --query id -o tsv)

# Assign least-privilege roles
az role assignment create --assignee-object-id "$FOUNDRY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Reader" --scope "$SEARCH_ID"

az role assignment create --assignee-object-id "$FOUNDRY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Search Service Contributor" --scope "$SEARCH_ID"
```

`Search Index Data Reader` lets the agent query the index. `Search Service Contributor` lets the portal list/inspect the index when you wire up the connection.

### 11.2 — Create the agent

In the [Microsoft Foundry portal](https://ai.azure.com/) (`iotopsfoundry` project):

1. Left pane → **Build and customize** → **Agents**.
2. Click **+ New agent**. Foundry assigns a default name and ID — rename it to `OEE Factory IQ`.
3. In the **Setup** pane on the right:
   - **Model deployment:** the `gpt-4.1` deployment from Step 9.2.
   - **Instructions:** paste the contents of [agent/system-prompt.md](agent/system-prompt.md) verbatim.
4. Click **Save** at the top before attaching tools.

The full agent definition is committed under [agent/agent.yaml](agent/agent.yaml) for reference and version control. The Foundry portal is the deployment target today; the YAML lives in source for review.

### 11.3 — Attach Knowledge tool #1: Fabric Data Agent

The Fabric Data Agent provides **live operational state** — `OEE_5min`, `MachineEvents`, `PartEvents`, `MaintenanceEvents`.

> Prereq: the Fabric Data Agent from Step 8.6 must be **published** in Fabric. Open it in the Fabric portal and check the publish status — Foundry can only connect to a published endpoint. Foundry and Fabric must share the same tenant and signed-in account.

From your agent's **Setup** pane, scroll to **Knowledge** → **Add**:

1. Choose **Microsoft Fabric**.
2. Click **New connection** (or pick an existing Fabric connection if you already created one).
3. From your published Fabric Data Agent's URL — it has the form `https://<env>.fabric.microsoft.com/groups/<workspace-id>/aiskills/<artifact-id>` — copy:
   - `workspace-id` — the GUID after `/groups/`.
   - `artifact-id` — the GUID after `/aiskills/`.
4. Paste both as custom keys in the connection dialog and check **Is secret** for each.
5. Name the connection (e.g., `oee-fabric-data-agent`), choose whether to share it across projects, and click **Connect**.
6. In the tool description field, paste the contents of [agent/knowledge/fabric_data_agent.md](agent/knowledge/fabric_data_agent.md) so the model knows when to call it.

Only one Microsoft Fabric tool is allowed per agent.

### 11.4 — Attach Knowledge tool #2: Azure AI Search

The Azure AI Search index provides the **static SOP corpus** — 36 PDFs from Step 10.

From the same **Knowledge** panel → **Add**:

1. Choose **Azure AI Search**.
2. Under **Connect to an index**, select **Indexes that are not part of this project**.
3. **Azure AI Search resource connection** → **New connection**:
   - **Service:** the AI Search service from Step 10.8 (subscription / resource group / name).
   - **Authentication:** **Microsoft Entra ID (managed identity)** — keyless. (Possible because Step 11.1 granted the Foundry MI the right roles.)
   - Click **Add connection**.
4. **Azure AI Search index:** `oee-sops`.
5. **Display name:** `oee-sops`.
6. **Search type:** **Hybrid + semantic**.
7. **Semantic configuration:** `oee-semantic` (from Step 10.5).
8. Click **Connect**.
9. In the tool description, paste the contents of [agent/knowledge/aisearch_sops.md](agent/knowledge/aisearch_sops.md).

> The model deployment you picked in 11.2 is used only for **orchestration and response generation**. The Fabric Data Agent uses its own model for NL2SQL; Azure AI Search uses the `text-embedding-3-large` deployment configured on the index itself.

### 11.5 — Run the sample queries

Open the agent's **Try in playground** view and try the prompts from [agent/samples/queries.md](agent/samples/queries.md). The set is organised by persona and tagged with the expected knowledge source(s):

- **Corp Exec** — "What's the site-wide OEE right now…"
- **Plant Manager** — "Show me OEE for all 5 lines over the past hour…"
- **Line Manager** — "On Line-B, list any stations currently in Fault…"
- **Maintenance Tech** — "Line-D Curing-Oven just raised a `Thermocouple-Drift` fault…"
- **Quality Worker** — "If Line-A CMM-Inspection rejects exceed 8 % in an hour…"

Validate that each response:

- Combines live state with procedure when the question demands it.
- Cites Fabric Data Agent for operational claims (with the table/view it queried).
- Cites the SOP PDF by filename for procedural claims (e.g., `Line-D_05_Curing-Oven_SOP.pdf`).
- Disambiguates `line_id` + `station_position` when a station type appears on more than one line (e.g., `Nozzle-Clog` exists on Line-D Primer/Paint and Line-E SMT/Conformal).

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
| **Ontology:** Graph shows 0 nodes/edges | Run diagnostic cell (Step 7b) to check for type mismatches between CSV declarations and actual table schemas; verify OneLake availability is enabled on the KQL Database |
| **Ontology:** `OEE_5min` table not found | Materialized views don't replicate to OneLake — either exclude OEEMetric entity or create a Delta table copy |
| **Ontology:** NonTimeSeries mapping error | Check that all NonTimeSeries bindings reference properties with `IsTimeseries=FALSE` in entity_types.csv |
| **Ontology:** Relationship binding fails | Verify `TargetKeyColumnNames` exist as properties in the SOURCE entity (not the target) |
