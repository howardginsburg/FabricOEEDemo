# Ontology and graph

The `OEEFactoryOntology` ontology is the plant's business model: what a station, a work order, or a part pass is,
how they relate, what each business rule requires, and which measure defines each KPI. It reads each part of the
plant from the source that holds it, and every agent in the demo reads it.

!!! info "Needs"
    Setup step [7](../setup/fabric-iq.md)

## The model

Open `OEEFactoryOntology`. Its 18 entity types sit in five namespaces:

| Namespace | Entity types |
|---|---|
| `equipment` | ProductionLine, Station, Machine, MachineType |
| `production` | Part, PartPass, Shift, ProductionSchedule, OeeTarget, OeeScorecard |
| `maintenance` | WorkOrder, MaintenanceEvent, Technician, IssueType |
| `knowledge` | Document, SOP, Policy |
| `floorops` | FloorIssue |

![The ontology's entity types and relationships](../assets/screenshots/demo/ontology-overview.png)

!!! quote "What to say"
    "This is the plant in business terms, not tables. Every agent we'll see reads this model, so they all agree on
    what a station or a work order is."

## Four sources, one model

Each entity reads the source that owns its data. Select one of each:

| Select | It reads | Point out |
|---|---|---|
| **Station** | The `ManufacturingLH` lakehouse | Properties such as `buffer_capacity` and `target_reject_rate`, bound to the lakehouse's `StationMaster` table |
| **Machine** | The `ManufacturingEH` Eventhouse | Its telemetry (`machine_status`, `idle_reason`, buffers, cycle time) is a set of time-series properties read live from `MachineEvents`, so the latest value is each machine's current state |
| **OeeTarget** | The `OeeGovernance` SQL database | The target a manager sets with the report's button, read straight from the database it's written to |
| **OeeScorecard** | The `OEEAnalytics` semantic model | The KPIs, which are the model's measures (see below) |

![The Station entity type and its binding](../assets/screenshots/demo/ontology-station.png)

!!! quote "What to say"
    "Each part of the plant comes from where it lives: the plant's records from the lakehouse, live telemetry and
    work orders from the Eventhouse with no copy in between, targets from the database the report writes to, and
    KPIs from the semantic model."

## Rules and metrics

The ontology's 13 rules restate the plant's policies from its SOPs: escalations, quarantines, lockout/tagout,
preventive maintenance, and how idle time is attributed. Each rule names the entities and properties it depends
on. Show **RejectRateQuarantine**, which uses each station's `target_reject_rate`.

![The RejectRateQuarantine rule](../assets/screenshots/demo/ontology-rules.png)

The KPIs are the 28 metrics on **OeeScorecard**: OEE and its factors, reject rate, throughput, schedule
adherence, MTTR, MTBF, target OEE, and the floor-issue KPIs. Each one is a measure in the `OEEAnalytics`
semantic model, which the ontology references instead of copying. Select **OeeScorecard**, then **View Entity
Type details**, open **OEE** in the **Metrics** section, and select **Resolve underlying DAX** to show its
definition from the model. Showing the DAX needs write permission on the model.

!!! quote "What to say"
    "The rules live here once. The data agent quotes them, and the operations agent enforces them. The KPIs live
    once too, in the semantic model, so the report, the ontology, and every agent show the same number."

## Ask the ontology

Select **Ontology agent** on the ontology's toolbar and ask in plain language. It picks the engine from each
entity's binding (KQL for the Eventhouse, SQL for the lakehouse and the SQL database, DAX for the semantic model,
and GQL for the graph) and shows the query it ran. Leave it in **Plan** mode, which can't change the ontology.

1. "What is the latest machine status of each station on Line-D?" It runs KQL over the Eventhouse.
2. "What is each line's current OEE target, and who set it?" It runs SQL over `OeeGovernance`.
3. "What is OEE by line, with availability, performance, and quality?" It runs DAX over `OEEAnalytics`.

!!! quote "What to say"
    "Ask the business model, and it knows where each answer lives: KQL for live telemetry, SQL for the records,
    DAX for the KPIs. The same model grounds every agent you'll see next."

## The graph

The ontology materializes as a graph, where each entity is a node and each relationship an edge. The graph loads
the plant's structure and records, while telemetry, events, and KPIs stay in their sources. Open the
**OEE Graph Queries** queryset and run its queries:

| Query | Shows |
|---|---|
| Line topology | Each line's stations and machine types, drawn as a graph |
| Part genealogy (latest Line-C parts) | The stations each recent part passed through, in order |
| Fault blast radius (mechanical wear) | The stations with mechanical-wear work orders, and how many parts went through them |
| Repeat-fault stations and their SOPs | The stations with the most work orders, with the SOPs a technician should open |
| Technician coverage by line | Work orders by technician and line |
| Floor issues by line and shift | Operator-logged issues by line, shift, and category |

![The Line topology query's graph](../assets/screenshots/demo/graph-query.png)

!!! quote "What to say"
    "Some questions are about connections: which parts went through a station that keeps failing, and which
    procedure covers it. The graph answers those by walking the relationships."

!!! tip "Generate an ontology from a semantic model"
    Fabric can also build an ontology from a semantic model: select **Generate ontology** on the model's ribbon.
    It turns the model's tables into entity types, its relationships into relationship types, and its measures into
    metrics, all bound to the model; keys, time series, and relationship bindings are left for you to add. This
    demo authors its ontology in TMDL instead, so each entity binds the source that owns its data, such as live
    telemetry from the Eventhouse, and takes only the KPIs from the model.
