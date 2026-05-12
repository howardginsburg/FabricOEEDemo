# Real-Time OEE Dashboard on Microsoft Fabric

A real-time **Overall Equipment Effectiveness (OEE)** dashboard built on [Microsoft Fabric](https://learn.microsoft.com/fabric/). A .NET simulator models a factory floor with **5 production lines (30 machines)** that stream machine telemetry, part events, and maintenance work orders. Two ingestion paths are supported:

| Path | Tutorial | Description |
|------|----------|-------------|
| **Direct to Fabric** | [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md) | Simulator connects directly to a Fabric Eventstream custom endpoint via Event Hub protocol. Simplest setup — no additional infrastructure required. |
| **Via Azure IoT Operations** | [AIO_OEE_TUTORIAL.md](AIO_OEE_TUTORIAL.md) | Simulator publishes to an MQTT broker managed by Azure IoT Operations. Stations are modeled as AIO assets, and a dataflow forwards telemetry to Fabric Eventstream. Mirrors a real factory edge-to-cloud pattern. |

Both paths land data in the same Fabric Eventhouse, KQL tables, materialized OEE view, and Real-Time Dashboard — the analytics layer is identical regardless of ingestion method.

This demo models **true production-line OEE** — parts flow sequentially through ordered stations, faults cascade starvation and blocking via bounded buffers, and maintenance work orders gate machine recovery.

**OEE = Availability × Performance × Quality**

**NEW — 4-pillar AI stack:** **Fabric RTI → Fabric IQ → Azure AI Search → Foundry Agent Service.** Live operational telemetry is fused with a 36-PDF SOP corpus and surfaced through a multi-persona Foundry agent. *(Work IQ integration coming next.)*

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
                   └──────────┬──────────────────────────┬──────────────────┘
                              │                          │
                              │ Fabric Ontology          │ (telemetry-only)
                              ▼                          │
                   ┌───────────────────────┐             │
                   │  Fabric IQ            │             │
                   │  Fabric Data Agent    │             │
                   │  (NL → KQL)           │             │
                   └──────────┬────────────┘             │
                              │                          │
                              │  KS#1 (live)             │
                              ▼                          │
                   ┌────────────────────────────────────┐│
                   │  Foundry Agent Service             ││
                   │  • System prompt (5 personas)      ││
                   │  • Routes between KS#1 & KS#2      ││
                   │  • Citations on every answer       ││
                   └──────────▲────────────┬────────────┘│
                              │            │             │
                  KS#2 (static)│            │ Chat UI     │
                              │            ▼             │
                   ┌────────────────────────┐            │
                   │  Azure AI Search       │            │
                   │  Index: oee-sops       │            │
                   │  36 PDFs · vector +    │            │
                   │  semantic + filters    │            │
                   └──────────▲─────────────┘            │
                              │                          │
                              │ Indexer (DocumentExtract │
                              │  → Split → AOAI embed)   │
                              │                          │
                   ┌──────────┴─────────────┐            │
                   │  Blob Storage          │            │
                   │  Container: oee-sops   │            │
                   │  36 SOP PDFs           │            │
                   └────────────────────────┘            │
```

> Work IQ integration is on the roadmap and not part of this checkpoint.

## Demo Storyline

The three persona vignettes below tie the four pillars together end-to-end.

### 1. Maintenance Tech — *"Fix the Hydraulic-Press, fast."*

A `Pressure-Loss` fault appears on Line-B station 02. The technician asks
the agent: *"Line-B Hydraulic-Press just faulted with Pressure-Loss —
walk me through the fix and confirm the work order is mine."* The agent
hits **Fabric IQ** (open work-order ID, assigned technician) and **AI
Search** filtered to `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf`
(corrective procedure + LOTO callout). The reply is one paragraph, one
numbered list, two citations.

### 2. Line Manager — *"Why is Line-D under target?"*

The Line-D OEE tile drops below 70 %. The Line Manager asks:
*"Show me Line-D OEE for the last hour and tell me which station is
the bottleneck right now."* Fabric IQ returns the trend and current
per-station status; AI Search retrieves the Curing-Oven bottleneck note
from `Production_Lines_Reference.pdf`. The agent recommends pausing
Coating-Inspection per the Reject Disposition Policy if the rate
crosses 5 %.

### 3. Plant Manager — *"Are we hitting the corporate OEE commitment?"*

Plant Manager asks: *"Which lines are below target right now, and what
does our escalation matrix require?"* The agent fans out — Fabric IQ
for live per-line OEE; AI Search for `OEE_Targets_and_Escalation.pdf`
to quote the 60 %/15 min / 60 %/1 hr thresholds. Output is a short
table with line, OEE, target, gap, and the required notification path.

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

## Get Started

Pick the path that fits how you want to learn:

- **[QUICKSTART.md](QUICKSTART.md)** — script-driven fast path. Uses the provisioners under `scripts/` to stand up the full 4-pillar stack (Fabric RTI → Fabric IQ Data Agent → Azure AI Search → Foundry agent) end-to-end. Best when you want a working demo quickly.
- **[FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md)** — manual step-by-step tutorial that builds the same stack through the Fabric and Azure portals. Best for learning the platform or for environments where the scripts cannot run.
- **[AIO_OEE_TUTORIAL.md](AIO_OEE_TUTORIAL.md)** — manual step-by-step tutorial for the optional ingestion variant that routes simulator telemetry through an Azure IoT Operations MQTT broker before Fabric.

The two manual tutorials and the quickstart all land at the same final architecture.

## Dashboard Pages

1. **Corporate Executive** — Factory OEE gauge, factory snapshot, line OEE trend, live OEE scores, OEE loss waterfall, machine status distribution
2. **Plant Manager** — OEE components breakdown, part throughput per line, MTTR by machine type, fault type Pareto, shift KPI summary, schedule adherence, completed vs rejected by line
3. **Line Manager** — Station pipeline, per-station OEE, cascade alerts (starved/blocked), actual vs ideal cycle time, parts funnel by station, quality trend, parts funnel (entered > passed > rejected)
4. **Maintenance Technician** — Faults by station, open work orders, work order lifecycle, equipment age vs OEE, cycle time anomaly detection, station availability heatmap, fault distribution treemap
5. **Quality / Station Worker** — Station status (live), factory KPIs, rejection rate by station, part journey (traceability), total parts produced, avg cycle time (time series)

## Repository Contents

| Path | Description |
|------|-------------|
| `QUICKSTART.md` | Scripted fast-path setup (Fabric, optional AIO, Foundry resource, AI Search, agent) |
| `FABRIC_OEE_TUTORIAL.md` | Step-by-step tutorial — direct to Fabric Eventstream (8 steps) |
| `AIO_OEE_TUTORIAL.md` | Step-by-step tutorial — via Azure IoT Operations MQTT broker |
| `scripts/1-setup-fabric.sh` | Automated Fabric provisioner script |
| `scripts/2-setup-iotops.sh` | Script to deploy OEE assets and dataflow to AIO via az CLI |
| `scripts/3-setup-iotops-assets.sh` | Bulk-promote discovered assets to managed assets |
| `scripts/4-setup-foundry.sh` | Provision the Foundry resource + project and deploy chat + embedding models (run before the AI Search script) |
| `scripts/5-setup-aisearch.sh` | Provision Azure AI Search + index the 36 SOP PDFs (uses the Foundry AOAI endpoint) |
| `scripts/build-sops.sh` | Regenerate SOP PDFs from `knowledge/source/*.md` (developer only) |
| `simulator/` | .NET 8 console app simulator |
| `simulator/FabricOEESimulator/` | Simulator source code |
| `simulator/FabricOEESimulator/simulator.sample.yaml` | Sample configuration file |
| `simulator/Dockerfile` | Docker build for the simulator |
| `dashboard/oee-dashboard.template.json` | Importable 5-page Real-Time Dashboard template |
| `ontology/` | Ontology CSV definitions for Data Agent (6 entities, 8 relationships) |
| `notebooks/create_ontology.ipynb` | Notebook to deploy ontology with validation and diagnostics |
| `docs/ONTOLOGY_LESSONS.md` | Lessons learned from ontology deployment (materialized views, type mismatches, validation) |
| `knowledge/` | 36 SOP PDFs + their markdown sources under `knowledge/source/` |
| `agent/` | Foundry prompt-agent scaffolding (`agent.yaml`, `system-prompt.md`, knowledge-source descriptions, sample queries) |
