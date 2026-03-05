# Real-Time OEE Dashboard on Microsoft Fabric

A real-time **Overall Equipment Effectiveness (OEE)** dashboard built on [Microsoft Fabric](https://learn.microsoft.com/fabric/). A .NET simulator models a factory floor with **5 production lines (30 machines)** that stream machine telemetry, part events, and maintenance work orders. Two ingestion paths are supported:

| Path | Tutorial | Description |
|------|----------|-------------|
| **Direct to Fabric** | [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md) | Simulator connects directly to a Fabric Eventstream custom endpoint via Event Hub protocol. Simplest setup — no additional infrastructure required. |
| **Via Azure IoT Operations** | [AIO_OEE_TUTORIAL.md](AIO_OEE_TUTORIAL.md) | Simulator publishes to an MQTT broker managed by Azure IoT Operations. Stations are modeled as AIO assets, and a dataflow forwards telemetry to Fabric Eventstream. Mirrors a real factory edge-to-cloud pattern. |

Both paths land data in the same Fabric Eventhouse, KQL tables, materialized OEE view, and Real-Time Dashboard — the analytics layer is identical regardless of ingestion method.

This demo models **true production-line OEE** — parts flow sequentially through ordered stations, faults cascade starvation and blocking via bounded buffers, and maintenance work orders gate machine recovery.

**OEE = Availability × Performance × Quality**

![OEE Dashboard](dashboard.png)

## Architecture

```
                   ┌───────────────────────────────────────────┐
                   │  .NET Simulator (5 lines, 30 stations)    │
                   │  Events: machine_telemetry | part_event   │
                   │          | maintenance_event              │
                   └─────────┬─────────────────┬───────────────┘
                             │                 │
            Option A (Direct)│                 │Option B (AIO)
                             │                 │
                 Event Hub Protocol        MQTT (port 1883)
                             │                 │
                             │                 ▼
                             │   ┌─────────────────────────────┐
                             │   │  Azure IoT Operations       │
                             │   │  MQTT Broker                │
                             │   │  ┌───────────────────────┐  │
                             │   │  │ Assets (30 stations)  │  │
                             │   │  └───────────────────────┘  │
                             │   │  Dataflow ──────────────────┼── Kafka (9093)
                             │   └─────────────────────────────┘       │
                             │                                         │
                             ▼                                         ▼
                   ┌──────────────────────────────────────────────────────────────┐
                   │  Fabric Eventstream                                          │
                   │  ├─ SQL: event_type='machine_telemetry'  ► MachineEvents     │
                   │  ├─ SQL: event_type='part_event'         ► PartEvents        │
                   │  └─ SQL: event_type='maintenance_event'  ► MaintenanceEvents │
                   └──────────────────────┬───────────────────────────────────────┘
                                          │
                                          ▼
                   ┌───────────────────────────────────────────────────────┐
                   │  Eventhouse — KQL Database                            │
                   │  [StationMaster]      ← reference (cycle times)       │
                   │  [LineMaster]         ← reference (line meta)         │
                   │  [ProductionSchedule] ← reference (shift plan)        │
                   │                                                       │
                   │  OEE_5min Materialized View                           │
                   │  Real-Time Dashboard (5 pages)                        │
                   │  Activator (fault + maintenance alerts)               │
                   └───────────────────────────────────────────────────────┘
```

## Production Lines

| Line | Name | Stations | Purpose |
|------|------|----------|---------|
| Line-A | Precision Machining | 5 | Raw bar stock → machined shaft |
| Line-B | Sheet Metal Forming | 4 | Sheet metal → stamped housing |
| Line-C | Welding & Assembly | 6 | Components → welded subassembly |
| Line-D | Surface Treatment | 7 | Raw part → painted/coated finished part |
| Line-E | Electronics Assembly | 8 | Bare PCB → tested electronics module |

### Station Details

#### Line-A: Precision Machining (Raw bar stock → machined shaft)

| # | Station | Ideal Cycle | Fault Rate | Reject Rate | Notes |
|---|---------|-------------|------------|-------------|-------|
| 1 | CNC-Lathe | 40 s | 0.5 % | 2 % | Turns raw bar stock into rough shaft profile |
| 2 | CNC-Mill | 45 s | 0.8 % | 3 % | Machines keyways, flats, and features |
| 3 | Surface-Grinder | 35 s | 0.3 % | 2 % | Grinds critical surfaces to final tolerance |
| 4 | Deburring-Station | 15 s | 0.2 % | 1 % | Removes machining burrs and sharp edges |
| 5 | CMM-Inspection | 60 s | 0.4 % | 5 % | Coordinate measuring machine validates dimensions (**bottleneck**) |

#### Line-B: Sheet Metal Forming (Sheet metal → stamped housing)

| # | Station | Ideal Cycle | Fault Rate | Reject Rate | Notes |
|---|---------|-------------|------------|-------------|-------|
| 1 | Blanking-Press | 8 s | 0.6 % | 2 % | Punches flat blanks from sheet metal |
| 2 | Hydraulic-Press | 12 s | 1.5 % | 4 % | Deep draws blanks into 3-D housing shape (**faultiest station**) |
| 3 | Trimming-Station | 10 s | 0.4 % | 2 % | Trims excess material and flash from formed part |
| 4 | Quality-Inspection | 20 s | 0.2 % | 3 % | Vision system checks dimensions and surface defects |

#### Line-C: Welding & Assembly (Components → welded subassembly)

| # | Station | Ideal Cycle | Fault Rate | Reject Rate | Notes |
|---|---------|-------------|------------|-------------|-------|
| 1 | Component-Loader | 10 s | 0.1 % | 0 % | Feeds raw components onto the line |
| 2 | Welding-Robot | 25 s | 0.7 % | 3 % | MIG/TIG robotic welding of joints |
| 3 | Weld-Inspection | 30 s | 0.5 % | 4 % | X-ray / ultrasonic non-destructive weld testing |
| 4 | Fastening-Station | 15 s | 0.3 % | 1 % | Torque-controlled bolt and fastener insertion |
| 5 | Assembly-Robot | 20 s | 0.4 % | 2 % | Robotic pick-and-place final assembly |
| 6 | Leak-Test | 25 s | 0.6 % | 3 % | Pressurized leak detection on sealed assemblies |

#### Line-D: Surface Treatment (Raw part → painted/coated finished part)

| # | Station | Ideal Cycle | Fault Rate | Reject Rate | Notes |
|---|---------|-------------|------------|-------------|-------|
| 1 | Surface-Prep | 20 s | 0.3 % | 1 % | Sand-blasts / abrasive-cleans the surface |
| 2 | Chemical-Wash | 30 s | 0.4 % | 1 % | Acid / alkaline wash to remove oils and oxides |
| 3 | Primer-Application | 25 s | 0.5 % | 3 % | Spray-applies primer coat |
| 4 | Paint-Booth | 40 s | 0.8 % | 4 % | Electrostatic or robotic paint application |
| 5 | Curing-Oven | 90 s | 0.6 % | 2 % | Heat-cures the paint/coating (**bottleneck**) |
| 6 | Coating-Inspection | 15 s | 0.2 % | 3 % | Vision + thickness gauge quality check |
| 7 | Final-Packaging | 10 s | 0.1 % | 0 % | Wraps and boxes finished parts for shipment |

#### Line-E: Electronics Assembly (Bare PCB → tested electronics module)

| # | Station | Ideal Cycle | Fault Rate | Reject Rate | Notes |
|---|---------|-------------|------------|-------------|-------|
| 1 | PCB-Loader | 5 s | 0.1 % | 0 % | Loads bare PCBs from magazine onto conveyor |
| 2 | SMT-Placement | 15 s | 0.6 % | 3 % | Pick-and-place mounts surface-mount components |
| 3 | Reflow-Oven | 45 s | 0.4 % | 2 % | Melts solder paste to bond SMT components |
| 4 | AOI-Inspection | 10 s | 0.3 % | 4 % | Automated optical inspection of solder joints |
| 5 | Through-Hole-Insert | 20 s | 0.5 % | 2 % | Inserts through-hole connectors and tall components |
| 6 | Wave-Solder | 35 s | 0.7 % | 3 % | Wave-solders through-hole leads (**faultiest station**) |
| 7 | Functional-Test | 30 s | 0.3 % | 5 % | Powers up board and runs electrical test suite |
| 8 | Conformal-Coat | 25 s | 0.4 % | 2 % | UV-cure conformal coating for environmental protection |

### Key Behaviors

- **Cascading faults:** A downed station starves downstream and blocks upstream via bounded buffers (capacity: 5 parts)
- **Maintenance gating:** Faulted machines enter Maintenance state and cannot resume until the work order is resolved
- **Part tracking:** Every part has a unique ID and full station-by-station traceability
- **OEE formula:** Availability = Running / (Running + Fault + Maintenance) — Starved/Blocked time is excluded

## Prerequisites

**Both paths:**
- Microsoft Fabric capacity (F2 or higher) with Real-Time Intelligence enabled
- A Fabric workspace with contributor access
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) installed (to build and run the simulator)
- OR [Docker](https://docs.docker.com/get-docker/) installed

**Azure IoT Operations path only (Option B):**
- Azure IoT Operations deployed ([Quickstart](https://github.com/howardginsburg/IoT-Operations-Quickstart))
- Azure CLI 2.67.0+ with the `azure-iot-ops` extension

## Quick Start

1. **Clone the repo:**
   ```bash
   git clone https://github.com/howardginsburg/FabricOEEDemo.git
   cd FabricOEEDemo
   ```

2. Setup Fabric (required for both paths):

      Follow [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md) for a step-by-step guide on manually setting things up.

      Alternatively, run the Fabric provisioner to create the Eventhouse, KQL Database, tables, reference data, materialized view, Eventstream with routing, and import the dashboard:
   ```bash
   bash scripts/1-setup-fabric.sh --workspace-name "My Workspace"
   ```

3. Add Azure IoT Operations (optional):**

   If routing telemetry through an AIO MQTT broker instead of connecting directly to Fabric, deploy the MQTT connector device and dataflow:

   See [AIO_OEE_TUTORIAL.md](AIO_OEE_TUTORIAL.md) for a step-by-step walkthrough.

   Alternatively, run these configuration steps:

   1. Deploy the MQTT connector into AIO.  This is a manual step and you can follow the [instructions](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector).

   2. Then run the script to create the Device with MQTT endpoint, wait for topic discovery, and promote discovered assets:

   ```bash
   
   bash scripts/2-setup-iotops.sh \
     --instance <your-aio-instance> \
     --resource-group <your-resource-group> \
     --workspace-name <fabric-workspace> \
     --eventhub-namespace <host> \
     --eventhub-name <es_xxx>
   ```

   3. After running the simulator for a while, you should see discovered assets in the AIO portal under the Device that is created. These assets then must be promoted to managed assets. The script promotes all station assets.

   If assets need to be re-promoted later:
   ```bash
   bash scripts/3-setup-iotops-assets.sh \
     --instance <your-aio-instance> \
     --resource-group <your-resource-group>
   ```
   

4. **Configure the simulator:**
   ```bash
   cd simulator/FabricOEESimulator
   cp simulator.sample.yaml simulator.yaml
   # Edit simulator.yaml — paste your Eventstream connection string (Option A)
   # or MQTT broker address (Option B)
   ```

5. **Run the simulator:**
   ```bash
   dotnet run
   ```
   
   Or with Docker:
   ```bash
   cd simulator
   docker build -t oee-simulator .
   docker run -it --rm -v "$(pwd)/FabricOEESimulator/simulator.yaml:/app/simulator.yaml" oee-simulator
   ```

## Dashboard Pages

1. **Corporate Executive** — Factory OEE gauge, factory snapshot, line OEE trend, live OEE scores, OEE loss waterfall, machine status distribution
2. **Plant Manager** — OEE components breakdown, part throughput per line, MTTR by machine type, fault type Pareto, shift KPI summary, schedule adherence, completed vs rejected by line
3. **Line Manager** — Station pipeline, per-station OEE, cascade alerts (starved/blocked), actual vs ideal cycle time, parts funnel by station, quality trend, parts funnel (entered > passed > rejected)
4. **Maintenance Technician** — Faults by station, open work orders, work order lifecycle, equipment age vs OEE, cycle time anomaly detection, station availability heatmap, fault distribution treemap
5. **Quality / Station Worker** — Station status (live), factory KPIs, rejection rate by station, part journey (traceability), total parts produced, avg cycle time (time series)

## Repository Contents

| Path | Description |
|------|-------------|
| `FABRIC_OEE_TUTORIAL.md` | Step-by-step tutorial — direct to Fabric Eventstream (7 steps) |
| `AIO_OEE_TUTORIAL.md` | Step-by-step tutorial — via Azure IoT Operations MQTT broker |
| `scripts/1-setup-fabric.sh` | Automated Fabric provisioner script |
| `scripts/2-setup-iotops.sh` | Script to deploy OEE assets and dataflow to AIO via az CLI |
| `scripts/3-setup-iotops-assets.sh` | Bulk-promote discovered assets to managed assets |
| `simulator/` | .NET 8 console app simulator |
| `simulator/FabricOEESimulator/` | Simulator source code |
| `simulator/FabricOEESimulator/simulator.sample.yaml` | Sample configuration file |
| `simulator/Dockerfile` | Docker build for the simulator |
| `dashboard/oee-dashboard.template.json` | Importable 5-page Real-Time Dashboard template |
