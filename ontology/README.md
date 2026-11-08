# OEE Factory Ontology (Fabric IQ)

`OEEFactoryOntology` is the plant's shared business model in **Fabric IQ**: the entity types,
their relationships, the business rules, and the governed metrics that every AI and analytics
surface in the demo reads. It uses the **new ontology experience**, whose item definition is
TMDL (the old JSON experience retires on January 31, 2027).

It binds every kind of source the demo has, each for what it's best at:

| Source | Binding | What it brings |
|---|---|---|
| `ManufacturingLH` lakehouse | Direct Lake through its SQL analytics endpoint | The plant's structure and records: lines, stations, machines, parts, schedules, work orders, documents, floor issues. The graph loads these. |
| `ManufacturingEH` Eventhouse | DirectQuery (`AzureDataExplorer.Contents`) | Live events with no mirror lag: machine telemetry, work order steps, part passes |
| `OeeGovernance` SQL database | Direct Lake through its SQL analytics endpoint | The OEE targets that the report's write-back button sets |
| `OEEAnalytics` semantic model | DirectQuery to the model (`EXTERNALMEASURE`) | The KPIs, defined once in DAX and referenced by name |

Who uses it:

| Consumer | How |
|---|---|
| OEE Data Agent ([scripts/7](../scripts/7-setup-data-agent.py)) | Its only source, as context. It queries the Eventhouse, the lakehouse, and the semantic model the ontology binds, with instructions and example queries mounted for the Eventhouse and the lakehouse; the ontology's rules and metric names are rendered into its instructions. |
| Ontology agent | The ontology's own chat (**Ontology agent** on its toolbar), which runs KQL, SQL, DAX, or GQL according to each entity's binding. |
| Foundry IQ knowledge base ([scripts/10](../scripts/10-setup-foundry-agent.py)) | `oee-ontology-ks`, a `fabricOntology` knowledge source next to the SOP index. |
| OEE Operations Agent ([scripts/11](../scripts/11-setup-operations-agent.py)) | Its alert rules come from the ontology's rules; each is checked by a `Rule<RuleName>()` function in `ManufacturingEH`. |
| Graph | `OEEFactoryOntology_graph_…`, with the saved queries in `OEE Graph Queries`. It loads the plant's structure and records, not the Eventhouse- or model-bound entities. |
| Ontology MCP endpoint | `ask_ontology`, `list_ontology_rules`, `list_ontology_entities` (user identity only). |

## Folder

```
ontology/
├── OEEFactoryOntology.Ontology/   the item definition, in TMDL (the format Fabric Git integration uses)
│   ├── .platform                  item type and display name
│   ├── database.tmdl
│   ├── expressions.tmdl           shared sources: ManufacturingLH, OeeGovernance, and OEEAnalytics
│   ├── tables/                    19 backing tables: 14 lakehouse, 3 Eventhouse, 1 SQL database,
│   │                              and _Measures (the semantic model's measures)
│   ├── relationships.tmdl         joins between backing tables
│   ├── namespaces/                equipment, production, maintenance, knowledge, floorops
│   ├── entities/                  18 entity types, one file each: <namespace>#<Entity>.tmdl
│   ├── entityRelationships.tmdl   16 relationship types
│   └── rules/                     13 business rules
└── graph-queries.json             GQL queries saved as the "OEE Graph Queries" queryset
```

The TMDL is the single source of truth. Descriptions (`///`), synonyms, and rule statements
live next to what they describe; this README only maps the model.

## Model

| Namespace | Entity types |
|---|---|
| `equipment` | `ProductionLine`, `Station` (a process position, key `device_id`), `Machine` (the asset at a station, with live telemetry as time series), `MachineType` (process-family rollup) |
| `production` | `Shift`, `ProductionSchedule` (plan per line and shift, key `schedule_id`), `OeeTarget` (each line's write-back target), `Part`, `PartPass` (one row per station pass), `OeeScorecard` (the plant's KPIs) |
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

**Metrics** come from the `OEEAnalytics` semantic model. `tables/_Measures.tmdl` references 28
of its measures (OEE and its factors at every grain, reject rate, MTTR, MTBF, schedule adherence,
target OEE, and their counts) with `EXTERNALMEASURE`, and the keyless `OeeScorecard` entity
exposes them. Each KPI is defined once, in DAX: the ontology shows the model's definition and
evaluates it in the model. `OeeScorecard` also binds the measures table's placeholder `Value`
column as a property, because a data agent reaches a source only through the entity properties
bound to it; without one, the agent never queries the model.

## Binding

Each backing table's partition names its source; the publisher injects the connections and the
`ONT_*` annotations that identify the item behind each table. Without the annotations the
definition is accepted, but the graph and the agents can't resolve the source.

- **Lakehouse** (14 tables): Direct Lake partitions on `ManufacturingLH` tables (schema `dbo`),
  through a `Sql.Database` expression on the lakehouse's SQL analytics endpoint, with eight
  `ONT_*` annotations. They are OneLake shortcuts to the Eventhouse's mirrored reference and
  record tables, plus `FloorEvent` (Floor Ops Console) when that layer is deployed. The ontology
  binds them through the SQL analytics endpoint, so it trails the Eventhouse by the OneLake export
  (about 5 minutes) and the endpoint's metadata sync.
- **Eventhouse** (`MachineTelemetry`, `MaintenanceEvents`, `PartPassResults`): DirectQuery
  partitions whose M source is `AzureDataExplorer.Contents(<query URI>, "ManufacturingEH",
  <table>)`, with the source columns recorded in an `ONT_SourceSchema` table annotation. `Machine`
  reads its telemetry (`machine_status`, `idle_reason`, `is_running`, buffers, cycle time) as
  time-series properties from `MachineEvents`, and `MaintenanceEvent` and `PartPass` read their
  events, all with no mirror lag. The lakehouse key column each one joins to is marked `isKey`.
- **SQL database** (`OeeTarget`): a Direct Lake partition on the `OeeGovernance` database's SQL
  analytics endpoint, shaped like a lakehouse table, so a target set with the report's
  write-back button reaches the ontology without a shortcut in between.
- **Semantic model** (`_Measures`): a DirectQuery partition on an `AnalysisServices.Database`
  expression named `DirectQuery to AS - <workspace id>/<model id>`, which the measures'
  `EXTERNALMEASURE` calls name. The publisher copies each measure's description, format, and
  lineage tag from `powerbi/OEEAnalytics.SemanticModel/definition/tables/_Measures.tmdl`, and
  stops if the ontology references a measure the deployed model doesn't have or with another data
  type. The signed-in user needs Read and Build permissions on the model.
- Keyed entities have a single key property; `ProductionSchedule` uses the computed
  `schedule_id` (line and shift). `PartPass`, `MaintenanceEvent`, and `OeeScorecard` are keyless.

## Publish

```bash
python scripts/6-publish-ontology.py --workspace-name "<WORKSPACE>"
```

`scripts/1-setup-fabric.sh` runs this for you (Step 6). Re-run it after scripts 2 to 4: entities
whose source doesn't exist yet are left out until it does (`OeeTarget` waits for the
`OeeGovernance` database from script 2, `FloorIssue` for the `FloorEvent` table from script 3,
and `OeeScorecard` for the `OEEAnalytics` model from script 4). The script's docstring lists every
step; the useful options are:

| Option | Does |
|---|---|
| `--refresh-graph` | Reloads the graph's data after publishing. |
| `--recreate` | Deletes the ontology and creates it again. |
| `--dry-run --out <dir>` | Writes the final definition parts without calling Fabric. |
| `--export-ttl <path>` | Writes the ontology as RDF Turtle (OWL classes and properties, with labels, descriptions, synonyms, and inheritance), using the portal Export's mapping. Generated on demand, not checked in. |

### Portal step: materialize the graph

The ontology's graph (`OEEFactoryOntology_graph_<id>`) is created empty. Open the ontology and
select **Manage graph** to load it; do it again after you add properties you want in the graph
(the projection can't be set through the definition, and the graph item itself is read-only).
The graph doesn't load entities bound to the Eventhouse or the semantic model: `Machine`,
`MaintenanceEvent`, and `PartPass` read the Eventhouse, `OeeScorecard` reads the semantic model,
and the abstract `Document` has no data of its own. `Station` carries the plant structure instead.
The graph's documented sources are lakehouse and mirrored-database tables. The current graph
(materialized before the redesign) loads `OeeTarget` from the lakehouse's `OeeTarget` shortcut;
the next **Manage graph** shows whether it can keep `OeeTarget` now that it's bound to the
`OeeGovernance` SQL database. No saved graph query uses it.
The graph keeps the sources it was materialized with until **Manage graph** runs again, so a
binding change doesn't reach the graph before then.
Once it has data, the publisher validates each query in `graph-queries.json` and saves the
passing ones as the **OEE Graph Queries** queryset. GQL labels are `<namespace>_<Entity>`; edge
labels repeat the namespace (`<ns>_<ns>_<Relationship>`).

## Change the ontology

1. Edit the TMDL. Give each new object a unique `lineageTag`. An entity that inherits from
   another (`baseEntityType`) must declare `overriddenMetadataField synonyms` when it sets its
   own synonyms.
2. To add a KPI, add the measure to the semantic model first and deploy it
   (`scripts/4-setup-powerbi.sh`), then add an `EXTERNALMEASURE` line for it to
   `tables/_Measures.tmdl`. The publisher fills in its description and format from the model.
3. Preview with `--dry-run`, then publish.
4. If the change adds a property the graph should expose, run **Manage graph** again. Materializing
   loads the data, so `--refresh-graph` isn't needed after it.
5. If the change adds a rule, re-run `scripts/7-setup-data-agent.py` (it renders the rules into
   the Data Agent's instructions). For an operations agent alert rule, also add its
   `Rule<RuleName>()` check function to `scripts/1-setup-fabric.sh` and its name to
   `ALERT_RULES` in `scripts/11-setup-operations-agent.py`, then re-run script 11 (it regenerates
   the playbook when the rules change).

## Known limits

- The graph doesn't load entities bound to the Eventhouse or the semantic model, so it shows the
  plant's structure and records, not live telemetry or KPIs.
- The ontology's natural-language queries over live data take 15 to 80 seconds, and a broad one
  (OEE for every station) can time out. Ask for one line, or ask the Data Agent.
- The `fabricOntology` knowledge source answers rule questions with the rule's content but not
  its name, and KPI questions with a summary, so the Foundry agent asks the Data Agent for KPIs.
- Data agents don't query entities bound to a SQL database, and can't mount one, so the Data
  Agent reads OEE targets from the semantic model's `Target OEE` measure, which reads the same
  table through OneLake. The ontology agent, the MCP endpoint, and the knowledge source read
  `OeeTarget` from `OeeGovernance` directly.
- Operations agents over an ontology evaluate only a property's latest value (no aggregations
  over a window), so the operations agent monitors `ManufacturingEH` and takes its rules from
  this ontology.
- The ontology MCP endpoint accepts user identities only, not service principals.

## References

- [Ontology overview](https://learn.microsoft.com/fabric/iq/ontology/overview)
- [Ontology definition (REST)](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/ontology-definition)
- [Graph in Microsoft Fabric](https://learn.microsoft.com/fabric/graph/overview)
