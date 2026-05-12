# Knowledge Source #1 — Fabric Data Agent

## Identity

- **Type:** Fabric Data Agent (Fabric IQ)
- **Role:** Live operational state
- **Backed by:** Fabric Eventhouse `ManufacturingEH`, KQL database
  `Manufacturing`, ontology built by `notebooks/create_ontology.ipynb`.

## What it knows

Tables and views (exposed by the Data Agent through the ontology):

| Object | Type | Purpose |
|---|---|---|
| `MachineEvents` | Table | Per-cycle machine status from every station. `machine_status`, `idle_reason`, `fault_type`. |
| `PartEvents` | Table | Per-part lifecycle (started/finished/rejected) across all 5 lines. |
| `MaintenanceEvents` | Table | Work-order lifecycle (`Open` → `Acknowledged` → `In Progress` → `Resolved`). |
| `OEE_5min` | Materialized view | Rolling 5-minute Availability × Performance × Quality by line & station. |
| `LineMaster` | Reference | The 5 lines, owner, target OEE. |
| `StationMaster` | Reference | The 30 stations, line, position, ideal/max cycle, reject target. |
| `ProductionSchedule` | Reference | Shifts A / B / C; technician rota T001–T008. |

## When to use

- "What's the current OEE on Line-D?"
- "Are there any open work orders right now?"
- "Which station on Line-E has been faulting the most this hour?"
- "Show me the reject rate trend on the Hydraulic-Press today."
- "Who is the technician on the Curing-Oven work order?"

## What it will NOT answer well

- "How do I fix a Nozzle-Clog?" — that is procedural; use the AI Search
  source.
- "What is the corporate OEE target?" — KPI policy lives in
  `OEE_Targets_and_Escalation.pdf` (AI Search).
- "What's the LOTO procedure?" — see
  `Safety_Lockout_Tagout_Procedure.pdf` (AI Search).

## Citation hint for the agent

When citing this source, summarise the underlying query, e.g.:

> *Data: OEE_5min for Line-D in the last 15 min; current OEE = 64 %.*
