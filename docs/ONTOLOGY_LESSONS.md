# Fabric Ontology — Architectural Rationale

This document explains *why* the OEE ontology looks the way it does — the
non-obvious design decisions that shaped both [`ontology/ontology.yaml`](../ontology/ontology.yaml)
and the Silver-tier KQL enrichment functions in [`scripts/1-setup-fabric.sh`](../scripts/1-setup-fabric.sh).

It does **not** document the deployment workflow itself. For that, see
[`ontology/README.md`](../ontology/README.md) and the publisher script
[`scripts/6-publish-ontology.py`](../scripts/6-publish-ontology.py), whose
structural validator catches binding mistakes (NonTimeSeries referencing
timeseries properties, missing FK columns, dual-bind drift) before any
REST call is made.

---

## Decision 1 — No `OEEMetric` entity; no Gold tier

KQL materialized views are the natural home for rolling OEE
(Availability × Performance × Quality), but they **do not replicate to OneLake**.
NonTimeSeries bindings that reference a materialized view fail silently — the
ontology creates successfully (HTTP 200) but the entity never appears in the
graph because the lakehouse `dbo` schema can't see the view.

The escape hatch is a Gold-tier Delta table populated by continuous export, but
that adds an orchestration component and an extra 5-minute lag on top of the
existing lakehouse mirror lag.

**What we did instead:** drop `OEEMetric` from the ontology and skip the Gold
tier entirely. Expose the *inputs* through the ontology and let the consumer
(Data Agent, Activator, dashboard) compose OEE at query time — see Decision 3
for the column-level mechanics.

---

## Decision 2 — Numeric proxy columns for every string status

The Fabric Data Agent's `TimeSeriesSelector` is restricted to a single column
with one of `Sum` / `Avg` / `Min` / `Max` / `Count`. It cannot run `countif`,
multiply, divide, join across entity types, or use window functions. Ask
*"how many minutes did Line-A run in the last hour?"* against a string column
like `machine_status` and the agent either fails or returns nonsense.

**Solution:** in the Silver-tier KQL update policy, add a boolean-as-int proxy
column alongside every status string the agent needs to summarise:

```kql
.create-or-alter function EnrichMachineEvents() {
    MachineEvents_Raw
    | extend
        is_running     = iff(machine_status == "Running", 1, 0),
        is_fault       = iff(machine_status == "Fault", 1, 0),
        is_idle        = iff(machine_status == "Idle", 1, 0),
        is_maintenance = iff(machine_status == "Maintenance", 1, 0)
}
```

Then `Avg(is_running)` over a window = fraction of time running = Availability.
The proxy lives next to the source string in the same enrichment function, so
both stay in sync. Storage cost is negligible (KQL packs int columns).

---

## Decision 3 — Push OEE math forward to query time

Given Decisions 1 and 2, OEE is **never stored**. Each component is exposed as
a raw proxy column on the Silver event tables, and the caller multiplies them:

| Component    | Source                                                                  | Computed at query time                     |
|--------------|-------------------------------------------------------------------------|--------------------------------------------|
| Availability | `MachineEvents.is_running` (Silver)                                     | `Avg(is_running)` over window              |
| Performance  | `MachineEventsEnriched()` view function (`MachineEvents` ⋈ `StationMaster`) — `performance_ratio` is null when not running | `Avg(performance_ratio)` over running rows |
| Quality      | `PartEvents.is_pass` filtered to `is_completed == 1`                    | `Avg(is_pass)` over completed parts        |
| OEE          | —                                                                       | `Availability × Performance × Quality`     |

`performance_ratio` and `ideal_cycle_time` are **not stored columns** on the
`MachineEvents` Silver table. Eventhouse update policies cannot `lookup` or
`join` other tables at ingest, so the Performance component is exposed through
the `MachineEventsEnriched()` view function, which joins `MachineEvents` to
`StationMaster` at query time. The dashboard, the Data Agent's KQL DB source,
and the Activator low-OEE rule all use the same view — no metric drift between
sources.

**Trade-off:** the cost is a recomputation per query versus one rolling
aggregation. At 5-line / 30-station scale with 5-minute Activator polling,
the cost is irrelevant. At site-of-sites scale with minute-granularity polling
it would not be.

---

## Decision 4 — Events are TimeSeries on dimensions, never entities

The original design modelled `MachineEvent`, `PartEvent`, and `MaintenanceEvent`
as standalone ontology entities. This failed at publish: Fabric's `NonTimeSeries`
Lakehouse binding requires the source table to have **one row per identifier**,
and the live event tables have huge duplication factors:

| Event entity | Source table | Rows | Distinct ids | Duplication |
|---|---|---|---|---|
| `MachineEvent` | `MachineEvents` | 85,312 | 30 device_ids | ~2843× |
| `PartEvent` | `PartEvents` | 30,181 | 2,826 part_ids | ~10× |
| `MaintenanceEvent` | `MaintenanceEvents` | 273 | 69 work_order_ids | ~4× |

Fabric responds **HTTP 200** and silently drops the offending entity. Worse,
every relationship that referenced a dropped entity cascade-drops, which is how
`ProductionSchedule` disappeared from the graph in our last broken publish
despite having a valid binding of its own.

The legal modelling is the FabricIQ canonical industrial-asset shape: **assets
are entities; telemetry is time series attached to assets**. The slim ontology
therefore has three entities — `ProductionLine`, `Station`, `ProductionSchedule`
— each bound to its already-unique reference table on the Lakehouse side
(`LineMaster`, `StationMaster`, `ProductionSchedule`) and to one or more event
tables on the Eventhouse side via TimeSeries bindings. Each entity may carry
multiple eventhouse bindings (Station has both `MachineEvents` and `PartEvents`),
and the publisher's per-binding `timeseries:` allowlist controls which TS
properties each source contributes.

Operational questions about individual parts and work orders — *"where is
P-12345?"*, *"is there an open WO on Curing-Oven?"* — are answered by the Data
Agent's **second data source**, the `ManufacturingEH` KQL Database, via NL2KQL
against the live event tables. No deduped dim tables are needed. See Decision 5.

---

## Decision 5 — Data Agent has two sources: slim ontology + KQL Database

The Fabric Data Agent supports multiple data sources on a single agent. We
attach two:

| Source | Purpose | Surface |
|---|---|---|
| **Ontology** (`OEEManufacturingOntology`) | Graph navigation, dimension lookups, time-series aggregates by line / station / shift | 3 entities, 2 relationships, `TimeSeriesSelector` |
| **KQL Database** (`ManufacturingEH`) | Single-record lookups, multi-table joins, full KQL expressiveness (countif, windowing, arg_max), proxy-column composition of OEE | All Bronze + Silver tables in `ManufacturingEH` |

This split eliminates the binding-contract conflict at the root. The ontology
keeps only what it can legally express; everything else falls through to
NL2KQL against the live event tables — which is what the dashboard already
does for every one of its 37 tiles. The KQL source is grounded with the same
queries as few-shot examples (see [`agent/knowledge/fabric_data_agent.md`](../agent/knowledge/fabric_data_agent.md)).

**No new Lakehouse tables. No scheduled pipelines. No `.set-or-replace` jobs.**
The slim ontology binds tables that `scripts/1-setup-fabric.sh` already creates
once at provisioning time; everything else is live Eventhouse data.

---

## Reference — Fabric Ontology property type mapping

Fabric silently drops an entity when a declared property type doesn't match the
actual Delta / KQL column type. The publisher's validator catches the YAML →
schema side, but the underlying compatibility matrix is still worth keeping
handy when adding new properties:

| Pipeline type   | YAML / Ontology type | Notes                                       |
|-----------------|----------------------|---------------------------------------------|
| C# `int`        | `BigInt`             | C# int → Delta int → Ontology BigInt (promoted) |
| C# `long`       | `BigInt`             | Direct                                      |
| C# `double`     | `Double`             | Direct                                      |
| C# `float`      | `Double`             | Float promotes to Double                    |
| C# `string`     | `String`             | Direct (also accepts `varchar`)             |
| C# `DateTime`   | `DateTime`           | C# DateTime → Delta timestamp → DateTime    |
| C# `bool`       | `Boolean`            | Direct                                      |

`String` ↔ numeric / `String` ↔ `DateTime` mismatches are the silent killers —
if a Silver table column gets re-typed without updating `ontology.yaml`, the
entity disappears from the graph with no error surfaced anywhere.

---

## Final shape

- **3 entity types:** `ProductionLine`, `Station`, `ProductionSchedule`.
- **2 relationships:** `Station_BelongsTo_ProductionLine`, `ProductionSchedule_For_ProductionLine`.
- **Hybrid bindings:** every entity carries a Lakehouse NonTimeSeries binding
  (its already-unique reference table) plus one or more Eventhouse TimeSeries
  bindings (live event streams joined on the entity's identifier).
- **Two-tier Medallion:** Bronze (`*_Raw`, Eventstream landing) → Silver
  (enriched with numeric proxy columns + OneLake-mirrored at ~5 min). No Gold
  tier and no materialized OEE view.
- **Two Data Agent sources:** the ontology (graph + slicing) plus the
  `ManufacturingEH` KQL Database (NL2KQL for single-record and complex queries).

---

## References

- [FabricIQ-Accelerators](https://github.com/microsoft/FabricIQ-Accelerators) — official Microsoft sample ontologies
- [Fabric Ontology API docs](https://learn.microsoft.com/fabric/real-time-intelligence/ontologies)
- [Fabric Ontology definition reference](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/ontology-definition) — verbatim binding contract
