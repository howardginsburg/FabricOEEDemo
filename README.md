# FabricOEEDemo

A real-time **Overall Equipment Effectiveness (OEE)** dashboard built on [Microsoft Fabric](https://learn.microsoft.com/fabric/). Simulates a factory floor with IoT devices streaming telemetry into Fabric Eventstream, then routes, enriches, and visualizes the data through KQL, Real-Time Dashboards, and Activator alerts.

Two simulator configurations are included — a **standard** config (14 devices, 2 lines) for quick demos and a **scaled** config (44 devices, 4 lines, 8 machine types) for more realistic workloads.

**OEE = Availability × Performance × Quality**

## Architecture

```
MQTTSimulator (Docker)
  Standard: 14 devices (10 machine + 4 maintenance)
  Scaled:   44 devices (36 machine + 8 maintenance)
       │
       │  Event Hub Protocol
       ▼
Fabric Eventstream
       │
       ├── SQL Query: event_type = 'machine_telemetry' ──► MachineEvents table
       │                                                     ├── MachineMaster (reference)
       │                                                     └── ProductionSchedule (reference)
       │
       └── SQL Query: event_type = 'maintenance_event' ──► MaintenanceEvents table
                                                             └── joins MachineEvents → MTTR

KQL Database ──► OEE_5min Materialized View
             ──► Real-Time Dashboard (OEE, MTTR, schedule adherence)
             ──► Activator (fault + unacknowledged maintenance alerts)
```

## Machine Fleet

### Standard Config (`devices.sample.yaml`) — 2 lines, 14 devices

| Device IDs | Machine Type | Line | Expected OEE | Report Interval |
|------------|-------------|------|-------------|----------------|
| cnc-mill-001/002/003 | CNC-Mill | Line-A | ~88% | 30s |
| press-001/002 | Hydraulic-Press | Line-A | ~45% | 10s |
| robot-001/002/003 | Assembly-Robot | Line-B | ~92% | 15s |
| packaging-001/002 | Packaging-Line | Line-B | ~55% | 5s |
| maint-cnc/press/robot/pkg | Maintenance CMMS | A & B | — | 45–330s |

### Scaled Config (`devices.scaled.yaml`) — 4 lines, 44 devices

| Device IDs | Machine Type | Line | Expected OEE | Report Interval |
|------------|-------------|------|-------------|----------------|
| cnc-mill-001–004 | CNC-Mill | Line-A | ~88% | 30s |
| press-001–003 | Hydraulic-Press | Line-A | ~45% | 10s |
| laser-001/002 | Laser-Cutter | Line-A | ~75% | 12s |
| robot-001–004 | Assembly-Robot | Line-B | ~92% | 15s |
| welder-001–003 | Welding-Robot | Line-B | ~70% | 12s |
| paint-001/002 | Paint-Booth | Line-C | ~65% | 45s |
| oven-001/002 | Heat-Treat-Oven | Line-C | ~80% | 90s |
| packaging-001–004 | Packaging-Line | Line-D | ~55% | 5s |
| maint-* (8 feeds) | Maintenance CMMS | A–D | — | 45–400s |

## Prerequisites

- Microsoft Fabric capacity (F2 or higher) with Real-Time Intelligence enabled
- A Fabric workspace with contributor access
- [Docker](https://docs.docker.com/get-docker/) installed

## Quick Start

1. **Clone the repo:**
   ```bash
   git clone https://github.com/howardginsburg/FabricOEEDemo.git
   cd FabricOEEDemo
   ```

2. **Follow the tutorial** — [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md) walks through every step:
   - Create an Eventstream with a custom endpoint
   - Configure and run the simulator
   - Create an Eventhouse with KQL tables and reference data
   - Route events with SQL Query operators
   - Build OEE KQL queries and a materialized view
   - Build a Real-Time Dashboard (manually or import the template)
   - Configure Activator alerts

3. **Configure the simulator:**
   ```bash
   # Standard (14 devices)
   cp devices.sample.yaml devices.yaml
   # — or Scaled (44 devices) —
   cp devices.scaled.yaml devices.yaml

   # Edit devices.yaml — paste your Eventstream connection string
   ```

4. **Run the simulator:**
   ```bash
   docker run -it --rm -v "$(pwd)/devices.yaml:/app/devices.yaml" ghcr.io/howardginsburg/mqttsimulator:latest
   ```
   > **Note:** The `-it` flags are required — the simulator uses [Spectre.Console](https://spectreconsole.net/) for its interactive UI and will exit immediately without a TTY.

## Repository Contents

| File | Description |
|------|-------------|
| [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md) | Step-by-step tutorial (Eventstream → Eventhouse → Dashboard → Activator) |
| [devices.sample.yaml](devices.sample.yaml) | Standard simulator config — 14 devices, 4 machine types, 2 lines |
| [devices.scaled.yaml](devices.scaled.yaml) | Scaled simulator config — 44 devices, 8 machine types, 4 lines |
| [oee-dashboard.template.json](oee-dashboard.template.json) | Pre-built Real-Time Dashboard (import into Fabric, replace `__CLUSTER_URI__` and `__DATABASE_ID__`) |
| [completed_tutorial_build.sh](completed_tutorial_build.sh) | Automated provisioning script — creates all Fabric items via REST API |

## Automated Setup

For a hands-off build, the provisioning script creates all Fabric items via the REST API:

```bash
# From WSL (Ubuntu)
bash completed_tutorial_build.sh --workspace-name "My Workspace"
```

Use `--use-device-code` for environments without interactive browser login.

The script:
- Creates the Eventhouse, KQL Database, and schema (tables, mappings, materialized view, reference data)
- Creates the Eventstream with Custom Endpoint source and Eventhouse destinations
- Generates and imports the Real-Time Dashboard with correct cluster URI and database ID
- Prompts for the Custom Endpoint connection string and generates `devices.yaml`

**Requirements:** WSL with `az` CLI logged in, `base64`, `sed` (jq is auto-installed if missing).

## OEE Formula

| Component | Formula |
|-----------|---------|
| Availability | Running messages ÷ total messages (per time window) |
| Performance | ideal_cycle_time (from MachineMaster) ÷ avg(actual_cycle_time) — when Running |
| Quality | 1 − (sum(rejected_parts) ÷ sum(total_parts)) |

> **Design principle:** The simulator sends only raw machine signals. `ideal_cycle_time` is engineering reference data stored in `MachineMaster`. `shift` is derived from the event timestamp in KQL. A single Eventstream fans out to two KQL tables via `event_type` routing.

## License

This project is provided as-is for demonstration purposes.