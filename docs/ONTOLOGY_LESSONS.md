# Fabric Ontology Deployment — Lessons Learned

This document captures critical insights from deploying the OEE Manufacturing Ontology with **hybrid lakehouse + eventhouse bindings**. These lessons prevent **silent failures** where the ontology creates successfully (HTTP 200/201) but the graph remains empty (0 nodes, 0 edges).

---

## Root Cause 1: Materialized Views Don't Replicate to OneLake

### Problem
KQL materialized views are not accessible via the lakehouse `dbo` schema because they don't replicate to OneLake. NonTimeSeries bindings that reference materialized views will fail silently — the ontology API returns success, but the entity type never appears in the graph.

### Detection
Run `spark.sql("DESCRIBE dbo.<table_name>")` for all NonTimeSeries binding sources:
- Base tables succeed
- Materialized views raise `TABLE_OR_VIEW_NOT_FOUND`

### Solution
**Option A — TimeSeries bindings only** (recommended for aggregated metrics):
Remove all NonTimeSeries bindings for entities backed by materialized views. Keep only TimeSeries bindings (KQL queries). The entity won't be indexed in the graph knowledge base, but users can still query it via natural language.

**Option B — Create a Delta table copy**:
Sync the materialized view to a Delta Lake table via scheduled notebook:
```python
# Read from KQL materialized view
df = spark.read \
    .format("com.microsoft.kusto.spark.synapse.datasource") \
    .option("kustoCluster", eventhouse_uri) \
    .option("kustoDatabase", "MyDB") \
    .option("kustoQuery", "MyMaterializedView") \
    .load()

# Write to Delta (merge/upsert for incremental updates)
df.write.format("delta").mode("overwrite").saveAsTable("dbo.MyTable")
```
Trade-off: Requires orchestration to keep Delta table fresh.

### Our Implementation
We excluded the `OEEMetric` entity from the ontology because:
- OEE_5min is a materialized view (5-minute rolling aggregates)
- Creating a Delta copy would require continuous syncing
- Users can query raw events (MachineEvent, PartEvent) and compute OEE on-demand

---

## Root Cause 2: Property Data Type Mismatch (Silent Failure)

### Problem
If the declared `PropertyDataType` in the CSV doesn't **exactly** match the Spark/Delta column type, Fabric silently drops the entire entity type. No error is returned — the ontology creates successfully, but the graph shows 0 nodes.

### Common Mismatches

| CSV Type | Spark Type | Valid? | Notes |
|----------|------------|--------|-------|
| `String` | `string` | ✅ | Perfect match |
| `String` | `varchar` | ✅ | Accepted as string variant |
| `BigInt` | `bigint` | ✅ | Perfect match |
| `BigInt` | `long` | ✅ | Long is equivalent to BigInt |
| `BigInt` | `int` | ✅ | Int is promoted to BigInt |
| `Double` | `double` | ✅ | Perfect match |
| `Double` | `float` | ✅ | Float is promoted to Double |
| `DateTime` | `timestamp` | ✅ | Perfect match |
| `DateTime` | `date` | ✅ | Date is accepted as DateTime |
| `String` | `int` | ❌ | **Type mismatch — entity dropped** |
| `BigInt` | `string` | ❌ | **Type mismatch — entity dropped** |
| `DateTime` | `string` | ❌ | **Type mismatch — entity dropped** |

### Detection
The notebook's diagnostic cell (Step 7b) runs `DESCRIBE` on all lakehouse tables and compares actual Spark types to declared CSV types:

```python
SPARK_TO_ONTOLOGY = {
    "string": "String", "varchar": "String",
    "bigint": "BigInt", "long": "BigInt", "int": "BigInt",
    "double": "Double", "float": "Double",
    "timestamp": "DateTime", "date": "DateTime",
}

df = spark.sql(f"DESCRIBE dbo.{table_name}")
for col in df.collect():
    actual_type = col["data_type"]
    expected_csv_type = SPARK_TO_ONTOLOGY.get(actual_type.lower())
    if expected_csv_type != declared_csv_type:
        print(f"MISMATCH: {col['col_name']} — CSV says {declared_csv_type}, table has {actual_type}")
```

### Solution
1. Run the diagnostic cell to identify mismatches
2. Update `PropertyDataType` in **both** `entity_types.csv` and `binding_entity_types.csv`
3. Re-upload CSVs to the lakehouse
4. Delete the ontology and recreate

---

## Root Cause 3: NonTimeSeries Bindings Referencing Timeseries Properties

### Problem
NonTimeSeries bindings (used for graph indexing) can **only** reference properties with `IsTimeseries=FALSE`. If a NonTimeSeries binding row has `IsTimeseries=TRUE`, the ontology creation fails with:

```
NonTimeSeries mapping at index N cannot reference timeseries property: <property_id>
```

### Detection
The validation cell (Step 3b) checks this before deployment:

```python
for row in binding_rows:
    if row["DataBindingType"] == "NonTimeSeries" and row["IsTimeseries"] == "TRUE":
        raise ValueError(f"NonTimeSeries binding for {row['PropertyName']} is timeseries")
```

### Solution
Split properties into two categories:

**Static properties** (`IsTimeseries=FALSE`) → NonTimeSeries bindings:
- Identifiers (device_id, part_id, work_order_id)
- Foreign keys (line_id, station_position)
- Display names (machine_type, line_name)

**Telemetry properties** (`IsTimeseries=TRUE`) → TimeSeries bindings:
- Timestamps
- Metrics (actual_cycle_time, buffer_count, parts_processed)
- Status fields (machine_status, idle_reason, event_type)

**Identifier duplication pattern:**
Identifiers appear in **both** binding types:
- **NonTimeSeries row**: `device_id (IsTimeseries=FALSE)` → enables graph joins
- **TimeSeries row**: `device_id (IsTimeseries=TRUE)` → enables KQL lookups

This pattern is seen in the [FabricIQ-Accelerators robotics sample](https://github.com/microsoft/FabricIQ-Accelerators/tree/main/Samples/Robotics).

---

## Root Cause 4: Relationship Binding TargetKeyColumnNames

### Problem
`TargetKeyColumnNames` in `binding_relationship_types.csv` must reference columns that exist **in the SOURCE entity** (not the target). If the column is missing or misspelled, the relationship fails silently.

### Detection
The validation cell (Step 3b) verifies this:

```python
entity_props = {(r["EntityTypeName"], r["PropertyName"]) for r in entity_rows}
for rel in rel_bind_rows:
    src = rel["SourceEntityTypeName"]
    for col in rel["TargetKeyColumnNames"].split(";"):
        if (src, col) not in entity_props:
            raise ValueError(f"TargetKeyCol '{col}' not found in {src}")
```

### Solution
For a relationship `SourceEntity -> TargetEntity`:
- `SourceKeyColumnNames`: Columns in the **source entity** definition
- `TargetKeyColumnNames`: **Also** columns in the **source entity** (these are the FK column names)
- Both must reference properties defined in the source entity's `entity_types.csv` rows
- Both must have `IsTimeseries=FALSE` (joins don't work on time-series properties)

Example:
```csv
RelationshipName,SourceEntityTypeName,TargetEntityTypeName,SourceKeyColumnNames,TargetKeyColumnNames
MachineEvent_RunsAt_Station,MachineEvent,Station,device_id,line_id;station_position
```
- `device_id`, `line_id`, and `station_position` must all exist in `MachineEvent` properties
- `line_id;station_position` is a composite FK that joins to `Station(line_id, station_position)`

---

## Best Practices

### 1. Validation Before Deployment
Always run the validation cell (Step 3b) before creating the ontology. It catches:
- NonTimeSeries → timeseries violations
- Missing TargetKeyColumnNames
- Non-String/BigInt identifiers
- Binding type inconsistencies

### 2. Diagnostic After Empty Graph
If the graph shows 0 nodes/edges despite successful creation, run the diagnostic cell (Step 7b) to compare CSV types against actual table schemas.

### 3. OneLake Availability Check
Verify OneLake availability is enabled on the KQL Database:
```bash
# Azure CLI
az rest --method get \
  --url "https://api.fabric.microsoft.com/v1/workspaces/{workspace_id}/kqlDatabases/{db_id}" \
  --resource "https://api.fabric.microsoft.com"
```
Look for `"oneLakeFolder": { "enabled": true }` in the response.

### 4. Test with Small Sample First
Create a minimal ontology (1 dimension + 1 event entity) to validate your binding approach before scaling to the full schema.

### 5. Document Type Mappings
Maintain a reference table of how your data pipeline's types map to Fabric Ontology types:

| Pipeline Type | Fabric CSV Type | Notes |
|--------------|----------------|-------|
| C# `int` | `BigInt` | C# int → Delta int → Ontology BigInt |
| C# `long` | `BigInt` | C# long → Delta bigint → Ontology BigInt |
| C# `double` | `Double` | Direct mapping |
| C# `string` | `String` | Direct mapping |
| C# `DateTime` | `DateTime` | C# DateTime → Delta timestamp → Ontology DateTime |
| C# `bool` | `Boolean` | Direct mapping |

---

## Ontology Architecture Summary

**Final working configuration:**
- **6 entity types**: 3 dimensions (ProductionLine, Station, ProductionSchedule) + 3 events (MachineEvent, PartEvent, MaintenanceEvent)
- **8 relationships**: All event types connect to ProductionLine and Station
- **51 bindings**: 27 NonTimeSeries (identifiers, FKs, display names) + 24 TimeSeries (telemetry)
- **OEEMetric excluded**: Backed by materialized view (no OneLake replication)

**Binding strategy:**
- **Dimensions**: 100% NonTimeSeries → lakehouse tables (LineMaster, StationMaster, ProductionSchedule)
- **Events**: Hybrid → identifiers/FKs via lakehouse, telemetry via KQL (MachineEvents, PartEvents, MaintenanceEvents)

**Key validation cells:**
1. CSV consistency check (Step 3b): Catches binding/definition mismatches
2. Type mismatch diagnostic (Step 7b): Compares CSV types to actual table schemas

---

## References

- [FabricIQ-Accelerators](https://github.com/microsoft/FabricIQ-Accelerators) — Official Microsoft sample ontologies
- [Robotics Sample](https://github.com/microsoft/FabricIQ-Accelerators/tree/main/Samples/Robotics) — Demonstrates identifier duplication pattern
- [Fabric Ontology API Docs](https://learn.microsoft.com/fabric/real-time-intelligence/ontologies) — Official documentation
- FabricOracleHFMDemo — Reference implementation that documented these failure modes
