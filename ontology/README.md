# OEE Factory Ontology (Fabric IQ)

`OEEFactoryOntology` is the plant's shared business model in **Fabric IQ**: the entity types,
their relationships, the business rules, and the governed metrics that every AI and analytics
surface in the demo reads. It uses the **new ontology experience**, whose item definition is
TMDL (the old JSON experience retires on January 31, 2027).

Who uses it:

| Consumer | How |
|---|---|
| OEE Data Agent ([scripts/7](../scripts/7-setup-data-agent.py)) | Ontology source first; its rules, metric names, and time-series properties are rendered into the agent's instructions. |
| Foundry IQ knowledge base ([scripts/10](../scripts/10-setup-foundry-agent.py)) | `oee-ontology-ks`, a `fabricOntology` knowledge source next to the SOP index. |
| OEE Operations Agent ([scripts/11](../scripts/11-setup-operations-agent.py)) | Its alert rules come from the ontology's rules; each is checked by a `Rule<RuleName>()` function in `ManufacturingEH`. |
| Graph | `OEEFactoryOntology_graph_…`, with the saved queries in `OEE Graph Queries`. |
| Ontology MCP endpoint | `ask_ontology`, `list_ontology_rules`, `list_ontology_entities` (user identity only). |

## Folder

```
ontology/
├── OEEFactoryOntology.Ontology/   the item definition, in TMDL (the format Fabric Git integration uses)
│   ├── .platform                  item type and display name
│   ├── database.tmdl
│   ├── expressions.tmdl           Direct Lake source: ManufacturingLH through its SQL analytics endpoint
│   ├── tables/                    18 backing tables over ManufacturingLH (schema dbo)
│   ├── relationships.tmdl         joins between backing tables
│   ├── namespaces/                equipment, production, maintenance, knowledge, floorops
│   ├── entities/                  17 entity types, one file each: <namespace>#<Entity>.tmdl
│   ├── entityRelationships.tmdl   16 relationship types
│   ├── rules/                     13 business rules
│   └── metrics/                   9 governed metrics
└── graph-queries.json             GQL queries saved as the "OEE Graph Queries" queryset
```

The TMDL is the single source of truth. Descriptions (`///`), synonyms, and rule statements
live next to what they describe; this README only maps the model.

## Model

| Namespace | Entity types |
|---|---|
| `equipment` | `ProductionLine`, `Station` (a process position, key `device_id`), `Machine` (the asset at a station, with live telemetry as time series), `MachineType` (process-family rollup) |
| `production` | `Shift`, `ProductionSchedule` (plan per line and shift, key `schedule_id`), `OeeTarget` (each line's write-back target), `Part`, `PartPass` (one row per station pass) |
| `maintenance` | `WorkOrder`, `MaintenanceEvent` (one row per lifecycle step), `Technician`, `IssueType` (fault code to category) |
| `knowledge` | `Document` (abstract), with `SOP` and `Policy` inheriting from it |
| `floorops` | `FloorIssue` (operator-logged events from the Floor Ops Console) |

**Relationships:** `StationOnLine`, `StationRunsMachineType`, `MachineAtStation`, `ScheduleForLine`,
`ScheduleForShift`, `TargetForLine`, `PartProcessedAtStation`, `PassOfPart`, `PassAtStation`,
`WorkOrderOnStation`, `WorkOrderAssignedTo`, `WorkOrderClassifiedAs`, `EventOfWorkOrder`,
`SopForStation`, `IssueAtStation`, `IssueDuringShift`.

**Rules** (natural-language statements tied to the properties they reference, from the SOPs and
policies): `LineOeeEscalation`, `StationOeeEscalation`, `LineOeeTarget`, `BottleneckDowntime`,
`RejectRateQuarantine`, `RepeatFaultsPreventiveMaintenance`, `ConcurrentOpenWorkOrders`,
`ShiftHandoverAgedWorkOrders`, `LockoutTagoutRequired`, `WorkOrderLifecycle`,
`StarvedBlockedRootCause`, `ShiftAttribution`, `AvailabilityDefinition`.

**Metrics** (SQL over the backing tables): `OEE`, `Availability`, `Performance`, `Quality`,
`RejectRate`, `MTTR`, `MTBF`, `ScheduleAdherence`, `TargetOee`. Each has a DAX twin in the
`OEEAnalytics` semantic model; `--check-metrics` compares them.

## Binding

- Every backing table is a Direct Lake partition on a `ManufacturingLH` table (schema `dbo`):
  OneLake shortcuts to the Eventhouse's mirrored tables, plus `OeeTarget` (translytical write-back)
  and `FloorEvent` (Floor Ops Console) when those layers are deployed.
- The source is a `Sql.Database` expression on the lakehouse's SQL analytics endpoint, and each
  partition carries the eight `ONT_*` annotations that identify the lakehouse item. The publisher
  injects both. Without the annotations the definition is accepted, but the graph and the Data
  Agent can't resolve the source.
- `Machine` reads its telemetry (`machine_status`, `idle_reason`, `is_running`, buffers, cycle
  time) as time-series properties from `MachineTelemetry` (the mirrored `MachineEvents`), so the
  ontology trails the Eventhouse by the OneLake mirror's latency (about 5 minutes). Windowed and
  minute-level questions go to the Eventhouse through the Data Agent.
- Keyed entities have a single key property; `ProductionSchedule` uses the computed
  `schedule_id` (line and shift). `PartPass` and `MaintenanceEvent` are keyless events.

## Publish

```bash
python scripts/6-publish-ontology.py --workspace-name "<WORKSPACE>"
```

`scripts/1-setup-fabric.sh` runs this for you (Step 6). Re-run it after scripts 2 and 3: entities
whose source table isn't in the lakehouse yet (`OeeTarget`, `FloorIssue`) are left out until it
is. The script's docstring lists every step; the useful options are:

| Option | Does |
|---|---|
| `--check-metrics` | Runs each SQL metric against the lakehouse and its DAX twin against `OEEAnalytics`, and reports drift. Needs `pyodbc` and ODBC Driver 18. |
| `--refresh-graph` | Reloads the graph's data after publishing. |
| `--recreate` | Deletes the ontology and creates it again. |
| `--dry-run --out <dir>` | Writes the final definition parts without calling Fabric. |
| `--export-ttl <path>` | Writes the ontology as RDF Turtle (OWL classes and properties, with labels, descriptions, synonyms, and inheritance), using the portal Export's mapping. Generated on demand, not checked in. |

### Portal step: materialize the graph

The ontology's graph (`OEEFactoryOntology_graph_<id>`) is created empty. Open the ontology and
select **Manage graph** to load it; do it again after you add properties you want in the graph
(the projection can't be set through the definition, and the graph item itself is read-only).
`Machine` isn't eligible because its telemetry is a second backing table, and neither are the
keyless events or the abstract `Document`; `Station` carries the plant structure instead.
Once it has data, the publisher validates each query in `graph-queries.json` and saves the
passing ones as the **OEE Graph Queries** queryset. GQL labels are `<namespace>_<Entity>`; edge
labels repeat the namespace (`<ns>_<ns>_<Relationship>`).

## Change the ontology

1. Edit the TMDL. Give each new object a unique `lineageTag`. An entity that inherits from
   another (`baseEntityType`) must declare `overriddenMetadataField synonyms` when it sets its
   own synonyms.
2. Preview with `--dry-run`, then publish.
3. If the change adds a property the graph should expose, run **Manage graph** again. Materializing
   loads the data, so `--refresh-graph` isn't needed after it.
4. If the change adds a rule, re-run `scripts/7-setup-data-agent.py` (it renders the rules into
   the Data Agent's instructions). For an operations agent alert rule, also add its
   `Rule<RuleName>()` check function to `scripts/1-setup-fabric.sh` and its name to
   `ALERT_RULES` in `scripts/11-setup-operations-agent.py`, then re-run script 11 (it regenerates
   the playbook when the rules change).

## Known limits

- Eventhouse-native (zero-lag) time-series bindings exist in the portal, but their TMDL shape
  isn't documented, so telemetry binds through the lakehouse.
- The `fabricOntology` knowledge source answers rule questions with the rule's content but not
  its name.
- Operations agents over an ontology evaluate only a property's latest value (no aggregations
  over a window) and don't support ontologies bound to a semantic model, so the operations agent
  monitors `ManufacturingEH` and takes its rules from this ontology.
- The ontology MCP endpoint accepts user identities only, not service principals.

## References

- [Ontology overview](https://learn.microsoft.com/fabric/iq/ontology/overview)
- [Ontology definition (REST)](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/ontology-definition)
- [Graph in Microsoft Fabric](https://learn.microsoft.com/fabric/graph/overview)
