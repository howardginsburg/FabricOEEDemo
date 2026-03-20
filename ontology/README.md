# OEE Manufacturing Ontology

This ontology models the Overall Equipment Effectiveness (OEE) manufacturing domain for the Fabric OEE Demo, enabling AI-powered semantic queries over production lines, stations, machine telemetry, parts, and maintenance events.

## Architecture

### Entity Types (6)

**Dimensions (static, indexed in graph):**
| Entity | Source Table | Key(s) | Purpose |
|---|---|---|---|
| **ProductionLine** | LineMaster | line_id | Production lines (5 lines: A-E) |
| **Station** | StationMaster | line_id + station_position | Stations within lines (~30 stations total) |
| **ProductionSchedule** | ProductionSchedule | line_id + shift | Production targets by line and shift |

**Events (hybrid: static skeleton + time series):**
| Entity | Source Table | Key(s) | Update Frequency |
|---|---|---|---|
| **MachineEvent** | MachineEvents | device_id + timestamp | Every 10 seconds (machine telemetry) |
| **PartEvent** | PartEvents | part_id + timestamp | Real-time (part enter/exit/reject) |
| **MaintenanceEvent** | MaintenanceEvents | work_order_id + timestamp | On maintenance state change (Created→Resolved) |

**OEEMetric excluded**: The OEE_5min table is a KQL materialized view which doesn't replicate to OneLake. NonTimeSeries bindings would fail with `TABLE_OR_VIEW_NOT_FOUND`. Users can query OEE data directly via KQL or create a Delta table copy.

### Relationships (8)

From dimensions:
- `Station_BelongsTo_ProductionLine` — Station → ProductionLine
- `ProductionSchedule_For_ProductionLine` — ProductionSchedule → ProductionLine

From MachineEvent:
- `MachineEvent_OccursOn_ProductionLine` — MachineEvent → ProductionLine
- `MachineEvent_RunsAt_Station` — MachineEvent → Station

From PartEvent:
- `PartEvent_OccursOn_ProductionLine` — PartEvent → ProductionLine
- `PartEvent_ProcessedAt_Station` — PartEvent → Station

From MaintenanceEvent:
- `MaintenanceEvent_OccursOn_ProductionLine` — MaintenanceEvent → ProductionLine
- `MaintenanceEvent_ServicesAt_Station` — MaintenanceEvent → Station

### Data Binding Strategy

**Static Bindings (indexed in graph, fast queries):**
- **Source:** KQL tables via OneLake availability (lakehouse bindings)
- **Purpose:** Graph indexing for fast traversals and joins
- **Entities:** All 6 entity types have static bindings for identifiers/FKs/display names
- **Query use case:** "Which stations on Line-A are CNC-Lathes?"

**Time Series Bindings (real-time lookup, always fresh):**
- **Source:** Eventhouse KQL tables (direct)
- **Purpose:** Real-time data queries without refresh lag
- **Entities:** MachineEvent, PartEvent, MaintenanceEvent (telemetry properties)
- **Query use case:** "Show current buffer status for Line-A stations"

## File Structure

```
ontology/
├── definition/
│   ├── entity_types.csv           # 6 entity types, 48 properties total
│   └── relationship_types.csv     # 8 relationships
├── binding/
│   ├── binding_entity_types.csv   # 51 property→column mappings (27 static + 24 timeseries)
│   └── binding_relationship_types.csv  # 8 relationship join specifications
└── README.md                       # This file
```

## CSV Format

### entity_types.csv
Defines entity types and their properties:
```csv
EntityTypeName,PropertyName,PropertyDataType,IsIdentifier,IsDisplayName,IsTimeseries
ProductionLine,line_id,String,TRUE,FALSE,FALSE
ProductionLine,line_name,String,FALSE,TRUE,FALSE
...
```

**Columns:**
- `EntityTypeName` — Entity type name (unique)
- `PropertyName` — Property name (1-26 chars, alphanumeric + hyphens/underscores)
- `PropertyDataType` — `String`, `BigInt`, `Double`, `Boolean`, `DateTime`
- `IsIdentifier` — `TRUE` if part of entity key (composite keys supported)
- `IsDisplayName` — `TRUE` for human-readable display property
- `IsTimeseries` — `TRUE` for event/timeseries entities

### relationship_types.csv
Defines relationships between entity types:
```csv
RelationshipName,SourceEntityTypeName,TargetEntityTypeName
Station_BelongsTo_ProductionLine,Station,ProductionLine
...
```

### binding_entity_types.csv
Maps properties to data source columns:
```csv
EntityTypeName,PropertyName,...,SourceTableName,BindingSourceColumnName,DataBindingType,SourceType,...
ProductionLine,line_id,...,LineMaster,line_id,NonTimeSeries,LakehouseTable,...
MachineEvent,device_id,...,MachineEvents,device_id,TimeSeries,EventhouseTable,...
```

**Key columns:**
- `SourceTableName` — KQL table name
- `BindingSourceColumnName` — Column name in source table
- `DataBindingType` — `NonTimeSeries` (static) or `TimeSeries` (real-time)
- `SourceType` — `LakehouseTable` (via OneLake) or `EventhouseTable` (direct)
- `TimestampColumnName` — For `TimeSeries` bindings, the timestamp column
- `ClusterUri`, `DatabaseName` — For `EventhouseTable` bindings
- `WorkspaceId`, `ItemId`, `SourceSchema` — Fabric workspace/item references

### binding_relationship_types.csv
Defines relationship joins:
```csv
RelationshipName,...,SourceKeyColumnNames,TargetKeyColumnNames,SourceTableName,...
Station_BelongsTo_ProductionLine,...,line_id;station_position,line_id,StationMaster,...
```

**Key columns:**
- `SourceKeyColumnNames` — Composite key of source entity (semicolon-separated)
- `TargetKeyColumnNames` — Matching columns in target entity (semicolon-separated)

## Deployment

### Prerequisites

1. **Fabric Workspace** with Real-Time Intelligence enabled
2. **ManufacturingEH Eventhouse** with KQL database created (via `scripts/1-setup-fabric.sh`)
3. **OneLake availability enabled** on the KQL database:
   - Fabric UI → ManufacturingEH KQL Database → Settings → OneLake availability → Enable
   - This exposes KQL tables as Delta tables in OneLake for lakehouse bindings
4. **Lakehouse** (any lakehouse in the workspace, used for uploading files)
5. **Ontology enabled** on your Fabric tenant (Admin Portal → Tenant settings → Ontology item)

### Steps

1. **Copy ontology files to lakehouse:**
   - Upload the CSV files from `ontology/` to `/lakehouse/default/Files/ontology/` in your lakehouse
   - Keep the folder structure intact: `definition/` and `binding/` subfolders
   - Download the latest `fabriciq_ontology_accelerator` wheel from the [FabricIQ Accelerator releases](https://github.com/microsoft/fabriciq-accelerator/releases) and upload that wheel to `/lakehouse/default/Files/ontology/`

2. **Run deployment notebook:**
   - Open `notebooks/create_ontology.ipynb` in Fabric
   - Execute all cells sequentially
   - The notebook will:
     - Auto-detect workspace, eventhouse, and lakehouse IDs
     - Substitute placeholders (`{WORKSPACE_ID}`, etc.) in binding CSVs
     - Package CSVs into a `.iq` ZIP file
     - Generate ontology definition with hybrid bindings
     - Create the ontology item in Fabric

3. **Verify deployment:**
   - Check that the ontology item was created (status 200/201)
   - Verify the GraphModel has 6 nodeTypes and 8 edgeTypes
   - Open the ontology in Fabric UI to preview the graph

### Troubleshooting

**"Lakehouse not available as data source"**
- Ensure OneLake availability is enabled on the KQL database (step 3 above)

**"Entity instances not shown in preview"**
- Check that KQL tables exist and have data
- Verify table names in binding CSVs match actual KQL table names
- Ensure composite keys are correctly defined (e.g., Station uses `line_id;station_position`)

**"GraphModel has 0 nodeTypes"**
- Wait a few minutes for the graph to populate
- Check that column names in binding CSVs exactly match KQL table column names
- Verify data types in `entity_types.csv` match KQL table column types

**"Column mapping enabled" error**
- KQL tables via OneLake don't have column mapping by default, so this shouldn't occur
- If it does, check for special characters in column names (`,`, `;`, `{}`, `()`, `\n`, `\t`, `=`, space)

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

**Note**: OEE calculations are not in the ontology. Query the `OEE_5min` materialized view directly via KQL for aggregate metrics.

### Graph Queries (GQL)

The ontology supports Graph Query Language (GQL) for complex graph traversals:

```gql
// Find all stations on Line-A with high fault rates
MATCH (line:ProductionLine {line_id: 'Line-A'})-[:Station_BelongsTo_ProductionLine]-(station:Station)
      (station)-[:MachineEvent_RunsAt_Station]-(event:MachineEvent)
WHERE event.machine_status = 'Fault'
RETURN station.machine_type, COUNT(event) AS fault_count
ORDER BY fault_count DESC
```

## Data Pipeline Integration

The ontology sits on top of the existing Fabric OEE Demo data pipeline:

1. **Simulator** → sends telemetry to MQTT broker or Event Hub
2. **Eventstream** → routes events to ManufacturingEH KQL tables (MachineEvents, PartEvents, MaintenanceEvents)
3. **KQL Materialized View** → computes OEE_5min from MachineEvents
4. **OneLake availability** → exposes KQL tables as Delta tables
5. **Ontology** → binds to tables via hybrid strategy (lakehouse + eventhouse)
6. **Data Agent** → natural language queries over the ontology

## Extending the Ontology

### Adding a New Entity Type

1. Add rows to `ontology/definition/entity_types.csv`:
   ```csv
   NewEntity,property1,String,TRUE,FALSE,FALSE
   NewEntity,property2,BigInt,FALSE,FALSE,FALSE
   ```

2. Add data bindings to `ontology/binding/binding_entity_types.csv`:
   ```csv
   NewEntity,property1,...,new_table,column1,NonTimeSeries,LakehouseTable,...
   ```

3. (Optional) Add relationships in both `definition/relationship_types.csv` and `binding/binding_relationship_types.csv`

4. Re-run the deployment notebook

### Adding Time Series Properties

For existing entities, add time series bindings:
```csv
EntityName,new_property,Double,FALSE,FALSE,TRUE,TableName,column,TimeSeries,EventhouseTable,timestamp,{URI},{DB},...
```

## References

- [Fabric Ontology Documentation](https://learn.microsoft.com/fabric/iq/ontology/overview)
- [Data Binding Guide](https://learn.microsoft.com/fabric/iq/ontology/how-to-bind-data)
- [fabriciq-accelerator](https://github.com/microsoft/fabriciq-accelerator) — source repository
- [FabricIQ Accelerator releases](https://github.com/microsoft/fabriciq-accelerator/releases) — download the wheel used by the notebook
- [Graph in Microsoft Fabric](https://learn.microsoft.com/fabric/graph/overview)

**Note:** This repo no longer vendors the `fabriciq_ontology_accelerator` wheel. Download the current wheel from the [FabricIQ Accelerator releases](https://github.com/microsoft/fabriciq-accelerator/releases) and upload it to your lakehouse before running the notebook.

## Property Summary

**ProductionLine** (4 properties): line_id, line_name, purpose, station_count  
**Station** (7 properties): line_id, station_position, machine_type, ideal_cycle_time, manufacturer, install_year, buffer_capacity  
**ProductionSchedule** (3 properties): line_id, shift, planned_parts  
**MachineEvent** (15 properties): device_id, timestamp, event_type, machine_type, machine_status, idle_reason, line_id, station_position, actual_cycle_time, input_buffer_count, output_buffer_count, buffer_capacity, total_parts_processed, rejected_parts, current_part_id  
**PartEvent** (9 properties): part_id, timestamp, event_type, line_id, station_position, machine_type, action, cycle_time, quality_pass  
**MaintenanceEvent** (10 properties): work_order_id, timestamp, event_type, device_id, machine_type, line_id, station_position, issue_type, action, technician_id

**Total**: 48 properties across 6 entity types, 51 bindings (27 NonTimeSeries + 24 TimeSeries), 8 relationships
