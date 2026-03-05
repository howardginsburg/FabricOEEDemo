# OEE Dashboard via Azure IoT Operations

Route the OEE simulator through an [Azure IoT Operations](https://learn.microsoft.com/en-us/azure/iot-operations/) MQTT broker so machine stations are automatically discovered as managed assets, then flow data into Microsoft Fabric for the same OEE dashboard built in the [main tutorial](FABRIC_OEE_TUTORIAL.md).

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│ Azure IoT Operations (Arc-enabled K3s cluster)                     │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ MQTT Broker                                                  │  │
│  │  LB Listener :1883 (no TLS, no auth)                         │  │
│  │                                                              │  │
│  │  Topics:                                                     │  │
│  │    oee/{lineId}/{deviceId}     ← machine_telemetry (30)      │  │
│  │    oee/{lineId}/parts          ← part_event (5)              │  │
│  │    oee/{lineId}/maintenance    ← maintenance_event (5)       │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                           │                                        │
│  ┌────────────────────┐   │   ┌─────────────────────────────────┐  │
│  │ MQTT Connector     │   │   │ Dataflow                        │  │
│  │  Topic filter:     │   │   │  Sources: unified/oee/#         │  │
│  │   oee/+/+          │   │   │           oee/+/parts           │  │
│  │  Asset level: 3    │   │   │           oee/+/maintenance     │  │
│  │  Prefix: unified   │   │   │  Dest: Fabric RTI endpoint      │  │
│  └────────────────────┘   │   └─────────────────────────────────┘  │
│                                            │ Entra ID (managed     │
└────────────────────────────────────────────│  identity)       ─────┘
         ^                                   ▼                       
         │ Port 1883                                                 
    .NET Simulator                 Fabric Eventstream                
    (5 lines, 30 stations)          [Custom endpoint source]         
                                           │                         
                                    ┌──────┴──────┐                  
                                    │ SQL Queries │                  
                                    ├─────┬───────┤                  
                                    │     │       │                  
                                    ▼     ▼       ▼                  
                              Machine  Part  Maintenance             
                              Events   Events  Events                
                                    │                                
                              Eventhouse (KQL)                       
                              + OEE Dashboard                        
```

## Prerequisites

- An Azure IoT Operations instance with the MQTT broker listening on port **1883** with anonymous access enabled (LoadBalancer listener), and network connectivity from the machine running the simulator to the broker IP. If you don't have one, follow the [IoT Operations Quickstart](https://github.com/howardginsburg/IoT-Operations-Quickstart) to deploy a VM, K3s cluster, and AIO instance with a single script.
- A [Microsoft Fabric workspace](https://learn.microsoft.com/en-us/fabric/get-started/create-workspaces) (not *my workspace*) with Real-Time Intelligence enabled
- **Tenant Admin** has enabled **Service principals can call Fabric public APIs** in the Fabric Admin portal
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) installed (to run the simulator)
- Azure CLI 2.67.0+ with the `azure-iot-ops` extension

## Topic Design

The simulator publishes to a three-level topic hierarchy under `oee/`:

| Event Type | Topic Pattern | Example | Asset? |
|---|---|---|---|
| Machine telemetry | `oee/{lineId}/{deviceId}` | `oee/line-a/line-a-station-1` | Yes — 1 per station (30 total) |
| Part events | `oee/{lineId}/parts` | `oee/line-a/parts` | No — transient items, not equipment |
| Maintenance events | `oee/{lineId}/maintenance` | `oee/line-a/maintenance` | No — operational records, not equipment |

The MQTT connector discovers assets at topic level 3 (the `{deviceId}` segment). The `parts` and `maintenance` topics also appear at level 3 but can be left as discovered assets without promotion — their data still flows through the dataflow to Fabric.

---

## 1. Setup Fabric

The Fabric analytics layer (Eventhouse, KQL Database, tables, Eventstream, and dashboard) is identical for both the direct and AIO ingestion paths. Set it up first by following [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md) Steps 1–6.

> **Scripted alternative:** `bash scripts/1-setup-fabric.sh --workspace-name "My Workspace"` creates everything in one command.

After completing this step, you should have:
- An Eventhouse named **ManufacturingEH** with a KQL database containing 3 event tables, 3 reference tables, and a materialized view
- An Eventstream named **manufacturing-telemetry** with a custom endpoint source and 3 SQL Query routing operators
- An OEE Real-Time Dashboard

---

## 2. Deploy the MQTT connector template (portal)

To have the simulator's MQTT messages automatically discovered as managed assets, deploy the MQTT connector template:

1. In the **Azure portal**, go to your IoT Operations instance
2. Select **Connector templates** → **Create a connector template**
3. Select **MQTT** as the type
4. Accept defaults through the wizard → **Create**

Once deployed, create a device and configure topic discovery in the [Operations Experience UI](https://iotoperations.azure.com). See [Configure the connector for MQTT](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector) for details.

---

## 3. Create a device and configure topic discovery

In the [Operations Experience UI](https://iotoperations.azure.com):

1. Go to **Devices** → **Create new**
2. Enter a name (e.g. `oee-simulator`)
3. Select **New** on the **Microsoft.Mqtt** tile
4. On the **Basic** tab:
   - **Endpoint name**: `oee-broker-endpoint`
   - **URL**: `mqtt://aio-broker-loadbalancer.azure-iot-operations.svc.cluster.local:1883` — the cluster-internal address of the MQTT broker. The connector runs inside the cluster, so it uses the internal service address rather than the external IP.
   - **Auth mode**: `Anonymous`
5. On the **Advanced** tab:
   - **Asset level**: `3` — picks the third segment of the topic path as the asset name. For `oee/line-a/line-a-station-1`, level 1=`oee`, level 2=`line-a`, level 3=`line-a-station-1`.
   - **Topic filter**: `oee/+/+` — discovers all three-level topics under `oee/`. This captures all 30 station topics, 5 parts topics, and 5 maintenance topics.
   - **Topic mapping prefix**: `unified` — messages arriving on `oee/line-a/line-a-station-1` are forwarded to `unified/oee/line-a/line-a-station-1`. This prevents a subscription loop when the connector subscribes to the same broker it forwards to. Do **not** include wildcards or a trailing `/`.
6. Select **Apply** to save the endpoint. Then select **Next** to continue.
7. On the **Add custom property** tab, optionally add metadata:
   - `environment` = `test`
   - `protocol` = `mqtt`
   - `source` = `oee-simulator`
8. Select **Next** → review the summary → **Create**

> **Scripted alternative:** `bash scripts/2-setup-iotops.sh --instance <name> --resource-group <rg>` creates the device and endpoint with the correct topic filter and asset level, then waits for topic discovery before promoting assets (see next step).

---

## 4. Discover and promote assets

### Discover assets

With the simulator running (see [Step 6](#6-configure-and-run-the-simulator)), go to **Discovery** in the Operations Experience UI. You should see discovered assets for each unique level-3 segment — 30 station assets (e.g. `line-a-station-1`), 5 `parts` assets, and 5 `maintenance` assets.

### Promote machine station assets

For each station:

1. Select a discovered asset (e.g. `line-a-station-1-xxxx`)
2. Select **Import and create asset**
3. On the **Asset details** page:
   - The inbound endpoint is already selected from the device
   - Use the discovered asset name as the asset name (must match)
   - Select **Next**
4. On the **Datasets** page:
   - A dataset is pre-populated from the discovered topic (e.g. `oee/line-a/line-a-station-1`)
   - The destination topic is `unified/oee/line-a/line-a-station-1`
   - Select **Next**
5. Select **Create**

> **Note:** Only station assets need to be promoted. The parts and maintenance topics are not promoted — the dataflow subscribes to their original `oee/+/parts` and `oee/+/maintenance` topics directly (see [Step 5](#5-create-a-dataflow-to-microsoft-fabric)).

> **Scripted alternative:** `bash scripts/3-setup-iotops-assets.sh --instance <name> --resource-group <rg>` bulk-promotes all discovered station assets via the ARM REST API.

---

## 5. Create a dataflow to Microsoft Fabric

Route all OEE telemetry from the unified namespace to a Fabric Eventstream using the IoT Operations system-assigned managed identity.

### Get the Eventstream connection details

In the Fabric portal, open the **manufacturing-telemetry** Eventstream (created in Step 1), select the **oee-simulator** custom endpoint source, choose **Entra ID Authentication**, and copy:
- **Event hub namespace** (e.g. `xxxx.servicebus.windows.net:9093`)
- **Event hub** name (e.g. `es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb`)

See [Connect to Eventstream using Microsoft Entra ID authentication](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/custom-endpoint-entra-id-auth) for details.

### Add the IoT Operations managed identity to the Fabric workspace

1. In the **Azure portal**, go to your IoT Operations instance → **Overview**
2. Copy the name of the extension listed after **Azure IoT Operations Arc extension** (e.g. `azure-iot-operations-xxxx7`)
3. In the **Fabric portal**, go to your workspace → **Manage access**
4. Search for the IoT Operations Arc extension name you copied
5. Assign the **Contributor** role and select **Add**

### Create the data flow endpoint

1. In the [Operations Experience UI](https://iotoperations.azure.com), go to **Data flow endpoints** → **Create new data flow endpoint** → **Microsoft Fabric Real-Time Intelligence** → **New**
2. Enter a **Name** (e.g. `oee-fabric-rti-endpoint`)
3. Set **Host** to the Event hub namespace from Fabric (e.g. `xxxx.servicebus.windows.net:9093`)
4. Set **Authentication method** to **System assigned managed identity**
5. Select **Apply**

### Create the dataflow

1. In the Operations Experience UI, go to **Dataflows** → **Create dataflow**
2. Configure the **source** with three MQTT topics:
   - `unified/oee/#` — station telemetry forwarded to the unified namespace by the MQTT connector
   - `oee/+/parts` — part events (not promoted, so not forwarded to unified)
   - `oee/+/maintenance` — maintenance events (not promoted, so not forwarded to unified)
3. Configure the **destination**:
   - Select the Fabric RTI endpoint you created (e.g. `oee-fabric-rti-endpoint`)
   - Set the **Topic** to the Event hub name from Fabric (e.g. `es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb`)
4. Under **Transform (optional)**, leave the default **PassThrough** mapping (all input fields are forwarded to the output)
5. Select **Create** to deploy the dataflow

> **Note:** The dataflow uses three sources because only station assets are promoted to the unified namespace. Part and maintenance topics remain on their original `oee/` prefix, so the dataflow subscribes to those directly. The multi-level `#` wildcard on `unified/oee/#` captures all station telemetry across all lines.

> **Scripted alternative:** `bash scripts/2-setup-iotops.sh --instance <name> --resource-group <rg> --workspace-name <ws> --eventhub-namespace <host> --eventhub-name <es_xxx>` creates the dataflow endpoint, grants the managed identity Contributor access on the workspace, and creates the dataflow.

Data should begin flowing into your Fabric Eventstream within a few minutes.

---

## 6. Configure and run the simulator

1. Navigate to the simulator directory and create your config:

```bash
cd simulator/FabricOEESimulator
cp simulator.sample.yaml simulator.yaml
```

2. Edit `simulator.yaml` — set the broker to MQTT with the AIO topic pattern:

```yaml
simulator:
  telemetryIntervalSeconds: 10

  broker:
    type: Mqtt
    host: <AIO_BROKER_IP_OR_HOSTNAME>
    port: 1883
    topic: "oee/{lineId}/{deviceId}"
```

3. Run the simulator:

```bash
dotnet run
```

Or with Docker (from the `simulator/` directory):

```bash
docker build -t oee-simulator .
docker run -it --rm -v "$(pwd)/FabricOEESimulator/simulator.yaml:/app/simulator.yaml" oee-simulator
```

4. Verify messages are arriving at the broker:

```bash
mosquitto_sub -h <AIO_BROKER_IP_OR_HOSTNAME> -p 1883 -t "oee/#" -v
```

You should see messages on 40 topics (30 station telemetry + 5 parts + 5 maintenance):
```
oee/line-a/line-a-station-1 {"event_type":"machine_telemetry","device_id":"line-a-station-1",...}
oee/line-a/parts {"event_type":"part_event","part_id":"P-00001",...}
oee/line-b/maintenance {"event_type":"maintenance_event","work_order_id":"WO-00001",...}
```

> **Note:** The simulator must be running before Step 4 can discover topics. You can start the simulator at any point after Step 2 — discovery happens automatically once messages arrive.

---

## Verify end-to-end flow

1. **MQTT broker** — confirm messages are arriving:

```bash
mosquitto_sub -h <AIO_BROKER_IP_OR_HOSTNAME> -p 1883 -t "oee/#" -v | head -20
```

2. **Unified namespace** — confirm the connector is forwarding messages (subscribe from inside the cluster or via the LB):

```bash
mosquitto_sub -h <AIO_BROKER_IP_OR_HOSTNAME> -p 1883 -t "unified/oee/#" -v | head -20
```

3. **Fabric Eventstream** — open the Eventstream in the Fabric UI and check the data preview

4. **KQL tables** — run verification queries in the Eventhouse:

```kql
MachineEvents | summarize count() by device_id | order by device_id asc
PartEvents | take 10 | order by timestamp desc
MaintenanceEvents | take 10 | order by timestamp desc
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Simulator can't connect to MQTT | Verify the broker IP/hostname and that port 1883 is reachable. Test with `mosquitto_pub -h <host> -p 1883 -t test -m hello` |
| No discovered assets in Operations Experience UI | Verify the MQTT connector template is deployed and the device/endpoint is created. Check that the topic filter `oee/+/+` matches the simulator's topic structure |
| Messages on `oee/#` but not on `unified/oee/#` | The MQTT connector is not running or the topic filter/prefix is misconfigured. Verify in the Operations Experience UI under **Devices** |
| Fabric Eventstream shows no data | Verify the dataflow is created with sources `unified/oee/#`, `oee/+/parts`, and `oee/+/maintenance`, and the IoT Operations managed identity has **Contributor** access on the Fabric workspace |
| KQL tables empty | Verify the Eventstream is published and the three SQL Query routing operators are connected to destinations |
| Simulator exits immediately | Run with `-it` flags for Docker; ensure `simulator.yaml` exists |
| All stations show "Starved" | Normal at startup — the first part needs to traverse the full line before output appears |

## References

- [Configure the connector for MQTT](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector)
- [Create a dataflow](https://learn.microsoft.com/en-us/azure/iot-operations/connect-to-cloud/howto-create-dataflow)
- [Configure data flow endpoints for Microsoft Fabric Real-Time Intelligence](https://learn.microsoft.com/en-us/azure/iot-operations/connect-to-cloud/howto-configure-fabric-real-time-intelligence)
- [Connect to Eventstream using Microsoft Entra ID authentication](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/custom-endpoint-entra-id-auth)
- [Configure MQTT broker listeners](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-brokerlistener)
