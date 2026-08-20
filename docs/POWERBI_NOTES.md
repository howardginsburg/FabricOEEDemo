# Power BI semantic model + report — notes & decisions (Component 0)

Checked-in PBIP project under [`powerbi/`](../powerbi): the `OEEAnalytics` **Direct Lake**
semantic model over `ManufacturingLH` and a 4-page report. Deployed by
[`scripts/2-setup-powerbi.sh`](../scripts/2-setup-powerbi.sh). This is the analytical/
historical lens that complements the real-time KQL dashboard — OEE is composed in **DAX**
here (mirroring the query-time KQL) rather than precomputed.

## Storage: Direct Lake over ManufacturingLH/dbo
All tables bind (partition `mode: directLake`) to Delta tables exposed through the
`ManufacturingLH` **SQL analytics endpoint**, schema `dbo`. The connection lives in
[`expressions.tmdl`](../powerbi/OEEAnalytics.SemanticModel/definition/expressions.tmdl) as a
single shared expression with two placeholders injected at deploy time:
`__SQL_ENDPOINT__` (endpoint server) and `__LAKEHOUSE_SQL_DB__` (the lakehouse name).

## Model shape (star schema)
- **Facts:** `MachineEvents`, `PartEvents`, `MaintenanceEvents`.
- **Dimensions:** `DimLine`, `StationDim`, `DimMachineType`, `DimShift`, `DimIssueType`,
  `DimTechnician`, `ProductionSchedule`, plus two blend tables (`DowntimeReason`,
  `OeeTarget`) populated by Components B and C.

### Key decision 1 — Station keyed on `device_id` (no duplicate table)
Direct Lake relationships must be **single-column**. Station identity is naturally
`(line_id, station_position)`, which is composite. Rather than a composite relationship or a
duplicate dimension table, `device_id` (a natural station attribute) is added **to
`StationMaster` itself**: `device_id = strcat(tolower(line_id),'-station-',station_position)`.
Both `scripts/1-setup-fabric.sh` (owner) and `scripts/2-setup-powerbi.sh` add it idempotently.
`device_id` already exists on `MachineEvents` and `MaintenanceEvents`, so a clean
single-column relationship works and `StationDim[ideal_cycle_time]` (bound to `StationMaster`)
is available to the **Performance** measure.

> **Mirror note (learned in deployment):** an *in-place* schema change on a OneLake-mirrored
> KQL table breaks its Delta mirror. So on an existing foundation where `StationMaster` lacks
> `device_id`, `scripts/2-setup-powerbi.sh` **drops and recreates** `StationMaster` (fresh
> table → clean mirror) only when `device_id` is missing, then re-enables mirroring with
> backfill. The mirror re-export takes a few minutes; the script triggers a model reframe and,
> if Performance/OEE are briefly blank, a re-run (or a manual Refresh) resolves it. Fresh
> installs get `device_id` directly from the `StationMaster` datatable in `scripts/1`, so no
> rebuild is needed.

### Key decision 2 — No modeled Date dimension
A Direct Lake date relationship needs a date-grain key on the fact, but the facts carry a
full-precision `timestamp` (datetime) and Direct Lake forbids calculated columns to derive
one. Rather than materialize a date key on every fact, trends use the fact `timestamp`
directly (Power BI bins it by date on a continuous axis) and Day/Night uses `DimShift`.
A materialized `DimDate` + fact date-key is a possible future enhancement.

### Key decision 3 — ProductionSchedule is unrelated (TREATAS)
`ProductionSchedule` grain is `(line_id, shift)`. Instead of a weak/composite relationship,
the **Planned Parts** measure maps the current `DimLine[line_id]` + `DimShift[shift]` filter
context onto it with `TREATAS`; **Schedule Adherence** = Parts Completed ÷ Planned Parts.

## DAX — the analytical source of truth for OEE
All measures live in
[`_Measures.tmdl`](../powerbi/OEEAnalytics.SemanticModel/definition/tables/_Measures.tmdl).
They mirror the dashboard's query-time KQL so the two layers agree:

| Measure | Definition (summary) |
| --- | --- |
| Availability | Running Samples ÷ Total Machine Samples (each row is exactly one status) |
| Performance | Σ ideal_cycle_time ÷ Σ actual_cycle_time over running rows, capped at 100% |
| Quality | Parts Passed ÷ Parts Produced (First-Pass Yield) |
| OEE | Availability × Performance × Quality |
| Rejection Rate | Parts Rejected ÷ Parts Produced |
| Throughput | Parts Completed |
| Planned Parts / Schedule Adherence | ProductionSchedule via TREATAS; Completed ÷ Planned |
| Work Orders | DISTINCTCOUNT(work_order_id) |
| MTTR (min) | avg(Resolved − Created) per work order, from MaintenanceEvents lifecycle |
| MTBF (min) | running-minutes ÷ failures (approx; see note) |
| OEE — Day / Night | OEE filtered by shift |
| Target OEE / OEE vs Target | from `OeeTarget` (Component C) |
| Downtime Reasons Logged | COUNTROWS(`DowntimeReason`) (Component B) |

Notes:
- **MTTR** relies on `MaintenanceEvents` carrying both `Created` and `Resolved` actions per
  `work_order_id` (the simulator emits the full lifecycle). Each `work_order_id` is a
  per-run GUID, so IDs never collide across simulator restarts.
- **MTBF** is approximate: it converts `Running Samples` to minutes assuming a 10-second
  telemetry cadence (`× 1/6`). Adjust the factor if the simulator's telemetry interval changes.
- **OEE parity:** after deploy, cross-check OEE / A / P / Q against the Real-Time Dashboard
  for the same window; small differences are expected (sampling vs event-time windows).

## Report (PBIR)
[`OEEAnalytics.Report`](../powerbi/OEEAnalytics.Report) has 4 pages — Executive OEE Overview,
Availability & Downtime, Performance & Cycle Time, Quality — with representative visuals wired
to the measures and shared Line/Shift slicers on the Executive page. The pages are a
**scaffold**: open the PBIP in Power BI Desktop to enrich layout/visuals. The deploy script
rebinds the report to the deployed semantic model (`byConnection`) automatically.

## Deploy
```bash
bash scripts/2-setup-powerbi.sh --workspace-name "<FABRIC_WORKSPACE>"
```
Idempotent: it adds `device_id` to `StationMaster`, injects the SQL endpoint connection, and
creates-or-updates both the semantic model and the report via the Fabric items definition API.
