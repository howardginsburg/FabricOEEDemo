# Knowledge Source #1 — Fabric Data Agent

## Identity

- **Type:** Fabric Data Agent
- **Role:** Live operational state
- **Backed by two sources** attached to the same Data Agent:
  1. **Ontology** — `OEEManufacturingOntology` (6 entities, 5 relationships,
     published from [`ontology/ontology.yaml`](../../ontology/ontology.yaml)
     by [`scripts/6-publish-ontology.py`](../../scripts/6-publish-ontology.py)).
  2. **KQL Database** — `ManufacturingEH` (Bronze `*_Raw` + Silver
     enriched tables, plus the `MachineEventsEnriched()` view function).
     Reached via NL2KQL with the dashboard's tile queries as canonical
     few-shot examples.

## Why two sources

The Fabric Ontology REST contract forces every NonTimeSeries Lakehouse binding
to have one row per identifier. The live event tables have huge duplication
factors (MachineEvents ~2843×, PartEvents ~10×, MaintenanceEvents ~4×), so they
cannot be ontology entities. We therefore model the **dimensions** in the
ontology (each already unique per identifier) and let the **KQL Database
source** handle anything that needs raw event lookup, complex KQL composition,
or single-record retrieval.

| Question shape | Best source |
|---|---|
| "What's the OEE on Line-D over the last hour?" | Either — ontology gives clean grouping, KQL DB gives the exact formula via the dashboard pattern |
| "Show me all stations currently in Fault" | Ontology — `Avg(is_fault)` per Station over last 30 s |
| "Where is part `P-12345` right now?" | KQL DB — single-record lookup, ontology cannot expose `Part` as an entity |
| "Is there an open work order on Curing-Oven?" | KQL DB — `MaintenanceEvents | where ... | arg_max(timestamp, *)` |
| "List the technicians acknowledging Line-B work orders today" | KQL DB — string column projection, ontology TS aggregates can't return rows |
| "How many parts has Line-E produced this shift vs planned?" | Ontology — `Sum(is_completed)` on `ProductionSchedule.PartEvents` joined to `planned_parts` |
| "Group OEE by machine-type category across all lines" | Either — ontology `Station_Is_Of_MachineType` → `MachineType.category`, or KQL DB join to `MachineTypeMaster` |
| "Which fault category causes the most downtime?" | KQL DB — `MaintenanceEvents` ⋈ `IssueTypeMaster` on `issue_type`, group by `category` |
| "What's the SOP for the Paint-Booth?" | Ontology `SOP_AppliesTo_Station` for the `file_name`, then AI Search for the text |

## Source #1 — Ontology surface

Six entities. The three **operational dimensions** below carry Lakehouse
NonTimeSeries identity + Eventhouse TimeSeries telemetry (each with its own
distinct DateTime timestamp per eventhouse binding, e.g. `ts_machine`,
`ts_part` — Fabric requires every TS property to map to exactly one source).
The three **reference dimensions** are lakehouse-only static lookups, each with
a graph edge. `IssueType`, `Technician`, and `Policy` are **not** ontology
entities — as graph nodes they would have no edge, so they live only in the KQL
Database source (see `IssueTypeMaster` / `TechnicianMaster` / `PolicyMaster`
below) and are joined via NL2KQL.

### `ProductionLine` (5 rows — `LineMaster`)

| Side | Source | Properties / metrics |
|---|---|---|
| Static | `LineMaster` (Lakehouse) | `line_id`, `line_name`, `purpose`, `station_count` |
| TS — machine | `MachineEvents` (Eventhouse) on `line_id` | `is_running`, `is_fault`, `is_idle`, `is_maintenance`, `actual_cycle_time` |
| TS — part | `PartEvents` (Eventhouse) on `line_id` | `is_pass`, `is_completed`, `is_rejected`, `cycle_time` |

### `Station` (30 rows — `StationMaster`)

| Side | Source | Properties / metrics |
|---|---|---|
| Static | `StationMaster` (Lakehouse) | `line_id`, `station_position`, `machine_type`, `ideal_cycle_time`, `manufacturer`, `install_year`, `buffer_capacity` |
| TS — machine | `MachineEvents` (Eventhouse) on `(line_id, station_position)` | `is_running`, `is_fault`, `is_idle`, `is_maintenance`, `actual_cycle_time`, `input_buffer_count`, `output_buffer_count` |
| TS — part | `PartEvents` (Eventhouse) on `(line_id, station_position)` | `is_pass`, `is_completed`, `is_rejected`, `cycle_time` |

### `ProductionSchedule` (10 rows — `ProductionSchedule`)

| Side | Source | Properties / metrics |
|---|---|---|
| Static | `ProductionSchedule` (Lakehouse) | `line_id`, `shift`, `planned_parts` |
| TS — part | `PartEvents` (Eventhouse) on `(line_id, shift_id)` | `is_pass`, `is_completed`, `is_rejected` |

### Relationships

- `Station_BelongsTo_ProductionLine`
- `ProductionSchedule_For_ProductionLine`
- `ProductionSchedule_For_Shift`
- `Station_Is_Of_MachineType`
- `SOP_AppliesTo_Station`

### Reference dimensions (lakehouse-only lookups)

| Entity | Rows | Source | Properties | Notes |
|---|---|---|---|---|
| `Shift` | 2 | `ShiftMaster` | `shift`, `start_hour`, `end_hour` | Day / Night windows. Edge: `ProductionSchedule_For_Shift`. |
| `MachineType` | 30 | `MachineTypeMaster` | `machine_type`, `category` | `category` rolls 30 types into 6 families (Machining / Forming / Joining / Surface / Electronics / Inspection). Edge: `Station_Is_Of_MachineType`. |
| `SOP` | 30 | `SopMaster` | `sop_id`, `line_id`, `station_position`, `machine_type`, `doc_type`, `title`, `file_name` | Station-scoped knowledge docs. Edge: `SOP_AppliesTo_Station`. `file_name` is the AI Search blob. |

`IssueType` (`IssueTypeMaster`), `Technician` (`TechnicianMaster`), and `Policy`
(`PolicyMaster`) are **not** ontology entities — their keys live only in event
data or are plant-wide, so they would be edgeless graph nodes. Query them from
the KQL Database source instead (see the KQL table list below).

Use `MachineType.category` (graph) or `IssueTypeMaster.category` (KQL) to compress the long tail of
machine and fault types into a handful of themes for cross-line rollups. For
the SOP/Policy `file_name`, hand off to the AI Search knowledge source
(`agent/knowledge/aisearch_sops.md`) to retrieve the full document text.

### Computing OEE through the ontology

The Fabric Data Agent's `TimeSeriesSelector` can only do `Sum` / `Avg` /
`Min` / `Max` / `Count` on a **single column**. So OEE is composed from three
independent aggregations:

| Component | Formula | Source via ontology |
|---|---|---|
| **Availability** | `Avg(is_running)` over the window | `ProductionLine` or `Station` TS — machine binding |
| **Quality** | `Avg(is_pass)` filtered to `is_completed == 1` | `ProductionLine` or `Station` TS — part binding |
| **Performance** | (not a single-column aggregate) | **Falls through to KQL DB source** — `MachineEventsEnriched() | where ... | summarize avg(performance_ratio)` |
| **OEE** | `Availability × Performance × Quality` | Composed by the agent in the answer text |

Performance requires a query-time join (`MachineEvents` ⋈ `StationMaster` to
compute `actual_cycle_time / ideal_cycle_time`), which the ontology's
TimeSeriesSelector cannot express. Use the KQL DB source for Performance and
for OEE composition.

## Source #2 — KQL Database surface

Tables (Silver tier — enriched on ingest via KQL update policies from
`*_Raw` Bronze tables):

| Object | Type | Purpose |
|---|---|---|
| `MachineEvents` | Silver table | Per-cycle machine status. String columns (`machine_status`, `idle_reason`) plus numeric proxies (`is_running`, `is_fault`, `is_maintenance`, `is_idle`). |
| `MachineEventsEnriched()` | View function | `MachineEvents` joined to `StationMaster` to populate `ideal_cycle_time` and `performance_ratio`. **Use this whenever Performance is involved.** |
| `PartEvents` | Silver table | Per-part lifecycle. String `action` plus numeric proxies (`is_pass`, `is_completed`, `is_rejected`). |
| `MaintenanceEvents` | Silver table | Work-order lifecycle (`Created` → `Acknowledged` → `InProgress` → `Resolved`). |
| `LineMaster` | Reference | The 5 lines, owner, target OEE. |
| `StationMaster` | Reference | The 30 stations, line, position, ideal cycle time, manufacturer. |
| `ProductionSchedule` | Reference | Shifts Day / Night; planned parts per line+shift. |
| `ShiftMaster` | Reference | Day / Night shift windows (`start_hour`, `end_hour`). |
| `MachineTypeMaster` | Reference | 30 machine types → `category` (6 process families). Join on `machine_type`. |
| `IssueTypeMaster` | Reference | 77 fault codes → `category` (6 fault themes). Join `MaintenanceEvents` on `issue_type`. |
| `TechnicianMaster` | Reference | 8 technicians (`technician_id` → `name`). Join `MaintenanceEvents` on `technician_id`. |
| `SopMaster` | Reference | 30 station SOPs (`file_name` = AI Search blob). |
| `PolicyMaster` | Reference | 6 plant-wide policy docs (`file_name` = AI Search blob). |

### Canonical NL2KQL patterns

**Current OEE for a single line (Performance composed from view function):**

```kql
let win = 15m;
let avail = MachineEvents
  | where line_id == "Line-A" and timestamp > ago(win)
  | summarize avg_running = avg(toreal(is_running));
let perf = MachineEventsEnriched()
  | where line_id == "Line-A" and timestamp > ago(win) and is_running == 1
  | summarize avg_perf = avg(performance_ratio);
let qual = PartEvents
  | where line_id == "Line-A" and timestamp > ago(win) and is_completed == 1
  | summarize avg_pass = avg(toreal(is_pass));
avail | extend Performance = toscalar(perf), Quality = toscalar(qual)
      | extend OEE = avg_running * Performance * Quality;
```

**Open work order on a specific station:**

```kql
MaintenanceEvents
| where line_id == "Line-D" and station_position == 5
| summarize arg_max(timestamp, *) by work_order_id
| where action != "Resolved"
| project work_order_id, device_id, line_id, station_position, machine_type,
  issue_type, action, technician_id, timestamp
```

**Mixed source pattern: current Fault/Maintenance stations plus open work orders**

Do not collapse this shape into one KQL query. Use the ontology first for
current station state, then KQL DB only for the work-order lookup:

1. Ontology source: `Station`, filter `line_id == "Line-B"`, recent window,
   aggregate `Avg(is_fault)` and `Avg(is_maintenance)` by
   `(line_id, station_position)`.
2. KQL DB source: query `MaintenanceEvents` for open work orders. Use a
   non-empty result shape so "none open" is a valid answer, not a failed step.

```kql
let open_work_orders =
  MaintenanceEvents
  | where line_id == "Line-B" and timestamp > ago(24h)
  | summarize arg_max(timestamp, *) by work_order_id
  | where action != "Resolved"
  | project line_id, station_position, work_order_id, issue_type,
    work_order_action = action, technician_id,
    work_order_timestamp = timestamp;
open_work_orders
| union (
  open_work_orders
  | summarize open_work_order_count = count()
  | where open_work_order_count == 0
  | project line_id = "Line-B", station_position = int(null),
    work_order_id = "", issue_type = "", work_order_action = "None",
    technician_id = "", work_order_timestamp = datetime(null)
)
| order by station_position asc
```

**Fault count by station in last hour:**

```kql
MachineEvents
| where timestamp > ago(1h)
| summarize faults = countif(machine_status == "Fault") by line_id, station_position
| order by faults desc
```

**Reject rate trend per station over the last 4 hours:**

```kql
PartEvents
| where timestamp > ago(4h) and is_completed == 1
| summarize rejects = sum(is_rejected), total = count() by bin(timestamp, 15m), line_id, station_position
| extend reject_rate = todouble(rejects) / total
```

**Where is a specific part?**

```kql
PartEvents
| where part_id == "LA-P-0f8c3a1e9b2c4d5e6f7a8b9c0d1e2f30"
| summarize arg_max(timestamp, *) by part_id
| project part_id, line_id, station_position, action, quality_pass, timestamp
```

**Downtime by fault category (join `MaintenanceEvents` ⋈ `IssueTypeMaster`):**

```kql
MaintenanceEvents
| where timestamp > ago(7d) and action != "Resolved"
| join kind=leftouter IssueTypeMaster on issue_type
| summarize fault_events = count() by category
| order by fault_events desc
```

**Work orders closed per technician this week (join `TechnicianMaster` for names):**

```kql
MaintenanceEvents
| where timestamp > ago(7d) and action == "Resolved"
| summarize closed = dcount(work_order_id) by technician_id
| join kind=leftouter TechnicianMaster on technician_id
| project technician = name, technician_id, closed
| order by closed desc
```

**OEE-style fault rollup by machine-type category (join `StationMaster` ⋈ `MachineTypeMaster`):**

```kql
MachineEvents
| where timestamp > ago(24h)
| join kind=leftouter MachineTypeMaster on machine_type
| summarize avg_running = avg(toreal(is_running)) by category
| order by avg_running asc
```

> The 37 dashboard tile queries in `dashboard/oee-dashboard.json` are the
> canonical training surface — they're the same KQL the agent should learn
> from. When in doubt, look there.

## When to use what

- **"current/recent operational state"** → either source. If grouping by line /
  station / shift cleanly answers it, prefer the ontology. If you need a join,
  a `countif`, a window, or a single-record lookup, use the KQL DB.
- **"where is X right now?"** → KQL DB (`arg_max(timestamp, *)` pattern).
- **"how many / what fraction"** over a sliceable axis → ontology TimeSeriesSelector.
- **"trend over time"** → KQL DB (binned `summarize`).
- **OEE composition** → KQL DB (Performance needs the view function join).
- **Procedural / how-to / KPI target** → not Data Agent at all; use the AI
  Search source on the SOP index.

## What it will NOT answer well

- "How do I fix a Nozzle-Clog?" — procedural, use the AI Search source.
- "What is the corporate OEE target?" — KPI policy lives in
  `OEE_Targets_and_Escalation.pdf` (AI Search).
- "What's the LOTO procedure?" — see
  `Safety_Lockout_Tagout_Procedure.pdf` (AI Search).

## Citation hint for the agent

Summarise the underlying query in every answer, e.g.:

> *Data (KQL DB): MachineEvents + MachineEventsEnriched() for Line-D, last 15 min.
> Availability = 0.81, Performance = 0.92, Quality = 0.86 → OEE ≈ 64 %.*

or

> *Data (Ontology): Station entity, `Avg(is_fault)` slice grouped by
> `(line_id, station_position)`, window = 30 s.*
