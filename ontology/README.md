# OEE Manufacturing Ontology

This ontology models the Overall Equipment Effectiveness (OEE) manufacturing domain for the Fabric OEE Demo, enabling AI-powered semantic queries over production lines, stations, schedules, machine types, and the station SOP knowledge base. Fault types, technicians, and plant-wide policies are queried through the Data Agent's KQL Database source rather than the graph (they have no graph edge).

## Architecture

The ontology follows the **slim-ontology** design (see `docs/ONTOLOGY_LESSONS.md`):
only dimensions with a unique-per-identifier source table become entities. Event
streams (MachineEvents, PartEvents, MaintenanceEvents) have duplicate natural
keys, so they are **not** entities — they bind as *time-series* properties on the
dimensions they describe and are queried via the Data Agent's KQL Database source.

### Entity Types (6)

**Operational dimensions (static identity + time-series telemetry):**
| Entity | Source Table | Key(s) | Purpose |
|---|---|---|---|
| **ProductionLine** | LineMaster | line_id | Production lines (5 lines: A-E). Time-series from MachineEvents + PartEvents. |
| **Station** | StationMaster | line_id + station_position | Stations within lines (30 total). Station *is* the device. Time-series from MachineEvents + PartEvents. |
| **ProductionSchedule** | ProductionSchedule | line_id + shift | Production targets by line and shift. Time-series from PartEvents. |

**Reference dimensions (static lookup, no time-series):**
| Entity | Source Table | Key(s) | Rows | Purpose |
|---|---|---|---|---|
| **Shift** | ShiftMaster | shift | 2 | Day / Night windows. |
| **MachineType** | MachineTypeMaster | machine_type | 30 | Machine model + `category` rollup (6 process families). |
| **SOP** | SopMaster | sop_id | 30 | Station-scoped knowledge docs; `file_name` joins to the Azure AI Search index. |

**OEE excluded by design**: OEE is composed on the fly from numeric proxy columns on the Silver `MachineEvents` and `PartEvents` tables (`is_running`, `performance_ratio`, `is_pass` filtered to `is_completed == 1`). No materialized view, no continuous export. The Data Agent, the Activator low-OEE rule, and the dashboard all use the same columns — no metric drift between sources. See `docs/ONTOLOGY_LESSONS.md` (Root Cause 6).

### Relationships (5)

- `Station_BelongsTo_ProductionLine` — Station → ProductionLine (StationMaster)
- `ProductionSchedule_For_ProductionLine` — ProductionSchedule → ProductionLine (ProductionSchedule)
- `ProductionSchedule_For_Shift` — ProductionSchedule → Shift (ProductionSchedule)
- `Station_Is_Of_MachineType` — Station → MachineType (StationMaster)
- `SOP_AppliesTo_Station` — SOP → Station (SopMaster)

**KQL-only reference tables (not ontology entities, no graph edge):** `IssueTypeMaster`,
`TechnicianMaster`, and `PolicyMaster` have keys that live only in event data or are
plant-wide, so as graph nodes they would be edgeless. They are deliberately left out
of the ontology and the Data Agent joins them via NL2KQL against the KQL Database
(e.g. `MaintenanceEvents` ⋈ `IssueTypeMaster` on `issue_type` to roll faults up
by category).

### Data Binding Strategy

Event tables follow a **two-tier Medallion**: Bronze `*_Raw` tables receive raw events from Eventstream, and KQL update policies enrich into Silver tables (`MachineEvents`, `PartEvents`, `MaintenanceEvents`) that the ontology binds against. Silver tables are OneLake-mirrored at 5-minute latency, so both binding sides see the same enriched data.

**Static Bindings (indexed in graph, fast queries):**
- **Source:** Silver KQL tables via OneLake availability (lakehouse bindings)
- **Purpose:** Graph indexing for fast traversals and joins
- **Entities:** All 6 entity types have lakehouse bindings for identifiers/FKs/display names. The 3 reference dimensions are lakehouse-only.
- **Query use case:** "Which stations on Line-A are CNC-Lathes?"

**Time Series Bindings (real-time lookup, always fresh):**
- **Source:** Eventhouse Silver KQL tables (direct)
- **Purpose:** Real-time data queries without 5-minute mirror lag
- **Entities:** ProductionLine, Station (telemetry from MachineEvents + PartEvents), ProductionSchedule (from PartEvents) — numeric proxies for OEE composition
- **Query use case:** "Show current buffer status for Line-A stations"

**Dual-bound slicers:** `line_id`, `station_position`, and `shift_id` are bound on **both** sides of every event entity. This lets the Data Agent's `TimeSeriesSelector` group time-series aggregates by line/station/shift without joining out to the dimension tables — which would otherwise fail because `device_id` (`line-a-station-1`) doesn't match `line_id` (`Line-A`).

## File Structure

```
ontology/
├── ontology.yaml   # Single nested manifest (entities + relationships)
└── README.md       # This file

scripts/
└── 6-publish-ontology.py   # Validates the YAML and publishes to Fabric via REST
```

## YAML Manifest

`ontology/ontology.yaml` is the single source of truth. Schema:

```yaml
ontology:
  name: OEEManufacturingOntology

entities:
  - name: <EntityType>
    identifiers: [<prop>, ...]        # composite keys supported
    displayName: <prop>               # optional; defaults to first identifier
    timestampProperty: <prop>         # required when timeseries: is present
    properties:                       # static props → LakehouseTable / NonTimeSeries
      - {name, type}                  # type ∈ String|BigInt|Double|Boolean|DateTime
    timeseries:                       # TS props → KustoTable / TimeSeries
      - {name, type}
    bindings:
      - target: lakehouse|eventhouse
        table: <delta or KQL table>
        columns: {<prop>: <col>}      # optional rename map
        slicers: [<prop>, ...]        # extra static props dual-bound on TS side

relationships:
  - name: <RelationshipName>
    source: <EntityType>
    target: <EntityType>
    binding:
      table: <delta table>
      sourceKey: [<prop>, ...]
      targetKey: [<prop>, ...]
```

Identifiers are dual-bound automatically. `slicers:` lets you also bind static properties such as `line_id`, `station_position`, and `shift_id` on the eventhouse side so the Data Agent can group time-series aggregates without joining out to dimensions.

## Deployment

### Prerequisites

1. **Fabric Workspace** with Real-Time Intelligence enabled
2. **ManufacturingEH Eventhouse** with KQL database created (via `scripts/1-setup-fabric.sh`)
3. **OneLake availability enabled** on the KQL database — Fabric UI → ManufacturingEH KQL Database → Settings → OneLake availability → Enable. This exposes KQL tables as Delta tables in OneLake for lakehouse bindings.
4. **ManufacturingLH Lakehouse** exists in the workspace with `Tables/dbo/<Table>` shortcuts to the OneLake-available KQL tables (`scripts/1-setup-fabric.sh` creates or refreshes this after OneLake availability is enabled)
5. **Ontology enabled** on your Fabric tenant (Admin Portal → Tenant settings → Ontology item)
6. **Local tooling:** Python 3.10+, `pip install pyyaml`, and `az login` against an identity with workspace contributor permissions

### Steps

1. **Validate the manifest (no REST calls):**
   ```bash
   python scripts/6-publish-ontology.py --dry-run --out .tmp/parts
   ```
   Inspect `.tmp/parts/` to see the multi-part REST definition the publisher will send.

2. **Publish to the workspace:**
   ```bash
   python scripts/6-publish-ontology.py --workspace-name <WORKSPACE>
   # add --recreate to delete + recreate the ontology in place
   ```
   The script resolves `ManufacturingLH` and `ManufacturingEH` by name, allocates deterministic IDs (BLAKE2b → BigInt, UUIDv5 → GUID), base64-wraps each part, and calls `POST /workspaces/{ws}/items` (or `updateDefinition` on an existing item).

3. **Verify deployment:** The script prints the new Ontology item ID on success. Fabric auto-provisions a companion `*_lh_*` Lakehouse and `*_graph_*` GraphModel; within a few minutes, the GraphModel should show 6 nodeTypes + 5 edgeTypes. Open the ontology in Fabric UI to preview the graph.

### Troubleshooting

**Validation errors before any REST call**
- The publisher runs structural validation first: identifier must be String/BigInt, `displayName` must be a declared property, `timestampProperty` must be `DateTime` and listed under `timeseries:`, etc. Fix `ontology.yaml` and rerun.

**`ItemDisplayNameNotAvailableYet` on create**
- Fabric reserves a deleted item's display name for a few minutes. The publisher retries every 30s for up to 10 minutes; just wait.

**"Lakehouse not available as data source"**
- Ensure OneLake availability is enabled on the KQL database (prereq 3).
- Re-run `scripts/1-setup-fabric.sh` after OneLake availability is enabled so `ManufacturingLH` and its `Tables/dbo/<Table>` shortcuts exist.

**"GraphModel has 0 nodeTypes"**
- Wait a few minutes for the graph to populate.
- Check that `bindings.table` and any `bindings.columns` overrides match the real KQL/Delta table and column names exactly.
- Verify `type:` for each property matches the underlying column type.

## Usage

### Data Agent Queries

Create a Fabric Data Agent connected to this ontology to query using natural language:

**Operational queries (real-time via time series bindings):**
- "What's the current machine status for all stations on Line-A?"
- "Show buffer counts for Line-C station 4"
- "List all parts rejected in the last hour"
- "Which machines are currently in fault state?"
- "Show all machine events for device Line-A_Stn1 in the last hour"

**Maintenance queries:**
- "Show all open maintenance work orders"
- "Which stations have the most maintenance events this week?"
- "What's the average time to resolve hydraulic press faults?"
- "Show maintenance history for Line-B station 2"

**Production tracking queries:**
- "Show the journey of part P-00042"
- "Which parts were processed by Line-C today?"
- "List all stations that processed parts in the last 30 minutes"

**Schedule queries:**
- "Show production schedules for all lines"
- "What's the planned target for Line-D day shift?"

**Reference-dimension queries:**
- "Group OEE by machine-type category across all lines" (MachineType.category, via the graph)
- "Which fault category causes the most downtime?" (KQL: MaintenanceEvents ⋈ IssueTypeMaster on issue_type)
- "How many work orders did each technician close this week?" (KQL: MaintenanceEvents ⋈ TechnicianMaster on technician_id)
- "What's the SOP for the Line-D Paint-Booth?" (SOP → Station via the graph, then retrieve `file_name` from AI Search)
- "Show the OEE-targets-and-escalation policy" (KQL: PolicyMaster → AI Search by `file_name`)

**Note**: OEE is not stored as an entity. The Data Agent composes it on the fly from Silver-tier numeric proxy columns (`MachineEvents.is_running`, `MachineEventsEnriched.performance_ratio`, `PartEvents.is_pass`). `MachineEventsEnriched()` is a view function that joins `MachineEvents` to `StationMaster` at query time to populate `ideal_cycle_time` and `performance_ratio` (Fabric Eventhouse update policies cannot do cross-table lookups). See `docs/ONTOLOGY_LESSONS.md` (Root Causes 5 and 6).

### Graph Queries (GQL)

The ontology supports Graph Query Language (GQL) for complex graph traversals:

```gql
// Find all CNC machining stations on Line-A and their machine-type category
MATCH (line:ProductionLine {line_id: 'Line-A'})<-[:Station_BelongsTo_ProductionLine]-(station:Station)
      -[:Station_Is_Of_MachineType]->(mt:MachineType)
WHERE mt.category = 'Machining'
RETURN station.machine_type, station.station_position, mt.category
ORDER BY station.station_position
```

## Data Pipeline Integration

The ontology sits on top of the existing Fabric OEE Demo data pipeline:

1. **Simulator** → sends telemetry to Event Hub
2. **Eventstream** → routes events to Bronze `*_Raw` tables in ManufacturingEH (MachineEvents_Raw, PartEvents_Raw, MaintenanceEvents_Raw)
3. **KQL update policies** → enrich Bronze → Silver tables (MachineEvents, PartEvents, MaintenanceEvents) adding numeric proxies (`is_running`, `is_fault`, `performance_ratio`, `is_pass`, ...) and shift/root-cause attributes
4. **OneLake mirroring** → Silver tables replicate to Delta at 5-min latency for graph-side bindings
5. **Ontology** → binds to Silver tables via hybrid strategy (lakehouse + eventhouse), with `line_id`/`station_position`/`shift_id` dual-bound for time-series slicing
6. **Data Agent** → natural language queries; composes OEE on the fly from the numeric proxies

## Extending the Ontology

### Adding a New Entity Type

1. Append the entity to `entities:` in `ontology/ontology.yaml`, declaring `identifiers`, `properties`, optional `timeseries`, and at least one `bindings:` entry.
2. (Optional) Add a relationship under `relationships:` referencing the new entity.
3. Republish: `python scripts/6-publish-ontology.py --workspace-name <WORKSPACE> --recreate`.

### Adding Time Series Properties

Add entries under the entity's `timeseries:` list and ensure an `eventhouse` binding exists for that entity (slicers go in `bindings[].slicers`). The publisher dual-binds identifiers automatically.

## References

- [Fabric Ontology overview](https://learn.microsoft.com/fabric/iq/ontology/overview)
- [Data Binding guide](https://learn.microsoft.com/fabric/iq/ontology/how-to-bind-data)
- [Ontology Definition REST reference](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/ontology-definition)
- [Graph in Microsoft Fabric](https://learn.microsoft.com/fabric/graph/overview)

## Property Summary

**Operational dimensions**
- **ProductionLine** (4 static): line_id, line_name, purpose, station_count — plus MachineEvents + PartEvents time-series.
- **Station** (7 static): line_id, station_position, machine_type, ideal_cycle_time, manufacturer, install_year, buffer_capacity — plus MachineEvents + PartEvents time-series.
- **ProductionSchedule** (3 static): line_id, shift, planned_parts — plus PartEvents time-series.

**Reference dimensions (lakehouse-only)**
- **Shift** (3): shift, start_hour, end_hour
- **MachineType** (2): machine_type, category
- **IssueType** (2): issue_type, category
- **Technician** (2): technician_id, name
- **SOP** (7): sop_id, line_id, station_position, machine_type, doc_type, title, file_name
- **Policy** (5): policy_id, scope, doc_type, title, file_name

**Total**: 9 entity types, 5 relationships. Event telemetry (MachineEvents, PartEvents, MaintenanceEvents) is queried via the Data Agent's KQL Database source, not modelled as entities.
