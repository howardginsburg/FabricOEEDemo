# Power BI semantic model + report — notes & decisions (Component 0)

Checked-in PBIP project under [`powerbi/`](../powerbi): the `OEEAnalytics` **Direct Lake**
semantic model over `ManufacturingLH` and a 5-page report (Executive OEE, Availability &
Downtime, Performance & Cycle Time, Quality, Floor Ops). Deployed by
[`scripts/4-setup-powerbi.sh`](../scripts/4-setup-powerbi.sh). This is the analytical/
historical lens that complements the real-time KQL dashboard — OEE is composed in **DAX**
here (mirroring the query-time KQL) rather than precomputed.

## Storage: Direct Lake on OneLake over ManufacturingLH/dbo
All tables bind (partition `mode: directLake`) to the Delta tables under
`ManufacturingLH/Tables/dbo`, read straight from OneLake: **Direct Lake on OneLake**, with no
SQL analytics endpoint in the query path and so no DirectQuery fallback. The connection lives
in [`expressions.tmdl`](../powerbi/OEEAnalytics.SemanticModel/definition/expressions.tmdl) as a
single shared expression (`AzureStorage.DataLake` on the lakehouse's OneLake URL) with two
placeholders injected at deploy time: `__WORKSPACE_ID__` and `__LAKEHOUSE_ID__`. Background
refreshes (reframes) succeed in this mode; the "cannot access the source Delta table" reframe
failures seen earlier were specific to Direct Lake on the SQL endpoint.

> **CRITICAL — the lakehouse must be schema-enabled (`enableSchemas: true`).** The Silver
> and reference tables are surfaced as OneLake shortcuts at `Tables/dbo/<Table>`, and the
> model binds to schema `dbo`. On a **non-schema** lakehouse, `dbo` is treated as a stray
> subfolder: the shortcuts land under `Tables/Unidentified/dbo`, the lakehouse can't identify
> them as Delta tables, and Direct Lake **framing fails**. `scripts/1-setup-fabric.sh` creates
> the lakehouse with `creationPayload.enableSchemas=true` and warns if an existing lakehouse
> lacks `properties.defaultSchema`.

## Model shape (star schema)
- **Facts:** `MachineEvents`, `PartEvents`, `MaintenanceEvents`.
- **Dimensions:** `DimLine`, `StationDim`, `DimMachineType`, `DimShift`, `DimIssueType`,
  `DimTechnician`, `ProductionSchedule`, plus two blend tables (`FloorEvent`,
  `OeeTarget`) populated by Components B and C.

### Key decision 1 — Station keyed on `device_id` (no duplicate table)
Direct Lake relationships must be **single-column**. Station identity is naturally
`(line_id, station_position)`, which is composite. Rather than a composite relationship or a
duplicate dimension table, `device_id` (a natural station attribute) is added **to
`StationMaster` itself**: `device_id = strcat(tolower(line_id),'-station-',station_position)`.
Both `scripts/1-setup-fabric.sh` (owner) and `scripts/4-setup-powerbi.sh` add it idempotently.
`device_id` already exists on `MachineEvents` and `MaintenanceEvents`, so a clean
single-column relationship works and `StationDim[ideal_cycle_time]` (bound to `StationMaster`)
is available to the **Performance** measure.

> **Mirror note (learned in deployment):** an *in-place* schema change on a OneLake-mirrored
> KQL table breaks its Delta mirror. So on an existing foundation where `StationMaster` lacks
> `device_id`, `scripts/4-setup-powerbi.sh` **drops and recreates** `StationMaster` (fresh
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
**Planned Parts** maps the current `DimLine[line_id]` + `DimShift[shift]` filter context onto it
with `TREATAS`. **Expected Parts** pro-rates each line's plan to the time the line ran (planned
parts × minutes in which its first station reported telemetry ÷ shift minutes), so time the
simulator wasn't running doesn't count against the plan. **Schedule Adherence** = Parts
Finished ÷ Expected Parts, where **Parts Finished** counts completions at the line's last
station (`DimLine[station_count]`); Parts Completed counts every station pass. The plans
themselves come from the line's bottleneck rate; `scripts/1-setup-fabric.sh` documents the
derivation where it seeds `ProductionSchedule`.

## DAX — the analytical source of truth for OEE
All measures live in
[`_Measures.tmdl`](../powerbi/OEEAnalytics.SemanticModel/definition/tables/_Measures.tmdl).
They share one definition per KPI with the Eventhouse functions `OeeFacts`/`OeeKpis` and the
ontology's metrics; `python scripts/6-publish-ontology.py --check-metrics` compares the
ontology's SQL metrics with these measures.

| Measure | Definition (summary) |
| --- | --- |
| Availability | Running Samples ÷ Total Machine Samples (each row is exactly one status) |
| Performance | Σ ideal_cycle_time ÷ Σ actual_cycle_time over running rows, capped at 100% |
| Quality | Parts Completed ÷ (Parts Completed + Parts Rejected), first-pass yield |
| OEE | Availability × Performance × Quality |
| Rejection Rate | Parts Rejected ÷ Parts Produced |
| Throughput / Parts Finished | Completions at the line's last station |
| Planned Parts / Expected Parts / Schedule Adherence | ProductionSchedule via TREATAS; the plan pro-rated to minutes run; Parts Finished ÷ Expected Parts |
| Work Orders | DISTINCTCOUNT(work_order_id) |
| MTTR (min) | avg(Resolved − Created) per work order, from MaintenanceEvents lifecycle |
| MTBF (min) | running minutes (Running Samples ÷ 6) ÷ Work Orders |
| OEE — Day / Night | OEE filtered by shift |
| Target OEE / OEE vs Target | from `OeeTarget` (Component C) |
| Floor Ops (Open Issues, Critical Open, Resolution Rate, Human MTTA/MTTR, Scrap Qty) | over `FloorEvent` (Component B) |

Notes:
- **MTTR** relies on `MaintenanceEvents` carrying both `Created` and `Resolved` actions per
  `work_order_id` (the simulator emits the full lifecycle). Each `work_order_id` is a
  per-run GUID, so IDs never collide across simulator restarts.
- **MTBF** is approximate: it converts `Running Samples` to minutes assuming a 10-second
  telemetry cadence (`× 1/6`). Adjust the factor if the simulator's telemetry interval changes.
- **OEE parity:** after deploy, cross-check OEE / A / P / Q against the Real-Time Dashboard
  for the same window; small differences are expected (sampling vs event-time windows).

## Report (PBIR)
[`OEEAnalytics.Report`](../powerbi/OEEAnalytics.Report) has 5 pages — Executive OEE Overview,
Availability & Downtime, Performance & Cycle Time, Quality, and Floor Ops — with visuals wired
to the measures, shared Line/Shift slicers, and (when `OeeTargetFunctions` exists) the
translytical write-back button on the Executive page. Open the PBIP in Power BI Desktop to
enrich the layout. The deploy script rebinds the report to the deployed semantic model
(`byConnection`) automatically.

## Deploy
```bash
bash scripts/4-setup-powerbi.sh --workspace-name "<FABRIC_WORKSPACE>"
```
Idempotent: it adds `device_id` to `StationMaster` if it's missing, injects the workspace and
lakehouse ids into the OneLake URL, creates or updates the semantic model and the report via the
Fabric items definition API, and reframes the model.
