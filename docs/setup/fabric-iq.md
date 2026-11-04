# 7. Fabric IQ

Step 1 already published the `OEEFactoryOntology` ontology and the OEE Data Agent. This step completes them
with what steps 3 to 5 added, and loads the ontology's graph.

## Update the ontology and the data agent

```bash
python3 scripts/6-publish-ontology.py --workspace-name "<FABRIC_WORKSPACE>" --check-metrics
python3 scripts/7-setup-data-agent.py --workspace-name "<FABRIC_WORKSPACE>" --smoke
```

- **Script 6** publishes the ontology from the TMDL in `ontology/OEEFactoryOntology.Ontology/`. This time it
  includes the entities whose tables steps 3 and 4 created, `OeeTarget` and `FloorIssue`, and the ontology's
  links to the Power BI report and the Real-Time Dashboard. `--check-metrics` runs each ontology metric's SQL
  against the lakehouse and its DAX twin against the semantic model, and reports any difference.
- **Script 7** adds the `OEEAnalytics` semantic model to the data agent's sources and publishes it again.
  `--smoke` asks the published agent one question per source.

## Materialize the graph

The ontology's graph starts empty, and loading it is a portal step:

1. Open `OEEFactoryOntology` and select **Manage graph** on the ribbon.
2. On **Configure Graph**, keep **Use the entire Ontology**. The entities that can't be in the graph are left
   out (see below). Select **Continue**.
3. On **Projection Summary**, select **Materialize**.

Loading takes a few minutes. When it's done, **Manage graph** shows the graph's status: 13 entity types
materialized, and the 4 that can't be in the graph (see below) unused.

![Manage graph after loading: 13 entity types materialized and 4 unused](../assets/screenshots/setup/manage-graph.png)

Then run script 6 again, without options: it checks the GQL queries in
`ontology/graph-queries.json` against the graph and saves the ones that pass as the **OEE Graph Queries**
queryset.

```bash
python3 scripts/6-publish-ontology.py --workspace-name "<FABRIC_WORKSPACE>"
```

These entities can't be in the graph:

| Entity | Why |
|---|---|
| `Machine` | Its telemetry comes from a second, time-series table. `Station` carries the plant structure in the graph. |
| `PartPass`, `MaintenanceEvent` | Events without a key |
| `Document` | Abstract: `SOP` and `Policy` inherit from it |

!!! warning "The graph is billed per use"
    Graph compute is billed by the second, and loading data is the expensive part. Each publish that changes
    the ontology reloads the graph's data, and so does **Manage graph**. Run **Manage graph** again only when
    you've added a property that the graph should show. To load the latest rows without other changes, use
    `--refresh-graph`. See [Capacity and cost](../reference/capacity.md).

## Verify

- `OEEFactoryOntology` shows 17 entity types. Select `Station` and preview its data.
- The workspace has the **OEE Graph Queries** queryset, and its queries return rows.
- Script 7's `--smoke` output shows an answer for each source.

To learn how the ontology is built, or to change it, see the
[ontology README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/ontology/README.md).
