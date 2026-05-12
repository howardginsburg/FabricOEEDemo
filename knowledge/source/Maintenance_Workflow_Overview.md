---
title: "Maintenance Workflow Overview"
doc_type: "Reference"
version: "1.0"
owner: "Maintenance Engineering"
last_reviewed: "2026-01-15"
---

# Maintenance Workflow Overview

> **Audience:** Maintenance Tech · Line Manager · Plant Manager
> **Applies to:** All 5 production lines, all 30 stations.

## 1. Purpose

This document is the canonical reference for the **fault → work-order →
resolution lifecycle** in this factory. Every per-station SOP cross-
references this overview. It names every `idle_reason` and `fault_type`
enum string the simulator can emit so the agent can map a telemetry event
to the correct SOP.

## 2. Telemetry values

The simulator's `machine_status` field takes one of:

- `Running` — station is processing a part within ideal-to-max cycle.
- `Idle` — no part being processed. Look at `idle_reason` to know why.
- `Fault` — a fault has been raised; see `fault_type` for the category.
- `Maintenance` — the maintenance work order is open and the station is
  held out of production until the WO is closed.

The simulator's `idle_reason` field takes one of:

- `Starved` — input buffer empty. The upstream station is not feeding parts.
- `Blocked` — output buffer full. The downstream station cannot accept the
  next part.

`idle_reason` is **null** when `machine_status` is `Running`, `Fault`, or
`Maintenance`.

## 3. Fault types by station (verbatim from `simulator.yaml`)

Every fault type below is documented in the corresponding station SOP under
section 4. The SOPs use the exact string as a heading so retrieval matches
the telemetry event.

### Line-A · Precision Machining

| Station | Fault types | SOP |
|---|---|---|
| CNC-Lathe | `Chuck-Jam`, `Bearing-Wear`, `Tool-Break` | `Line-A_01_CNC-Lathe_SOP.pdf` |
| CNC-Mill | `Spindle-Vibration`, `Coolant-Leak`, `Tool-Wear` | `Line-A_02_CNC-Mill_SOP.pdf` |
| Surface-Grinder | `Wheel-Wear`, `Coolant-Clog`, `Alignment-Drift` | `Line-A_03_Surface-Grinder_SOP.pdf` |
| Deburring-Station | `Brush-Wear`, `Motor-Overheat`, `Jam` | `Line-A_04_Deburring-Station_SOP.pdf` |
| CMM-Inspection | `Probe-Calibration`, `Air-Supply`, `Sensor-Fail` | `Line-A_05_CMM-Inspection_Calibration.pdf` |

### Line-B · Sheet Metal Forming

| Station | Fault types | SOP |
|---|---|---|
| Blanking-Press | `Die-Wear`, `Alignment-Fault`, `Feed-Jam` | `Line-B_01_Blanking-Press_SOP.pdf` |
| Hydraulic-Press | `Pressure-Loss`, `Seal-Failure`, `Valve-Fault` | `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf` |
| Trimming-Station | `Blade-Dull`, `Guard-Trip`, `Alignment-Shift` | `Line-B_03_Trimming-Station_SOP.pdf` |
| Quality-Inspection | `Camera-Fault`, `Sensor-Drift`, `Light-Failure` | `Line-B_04_Quality-Inspection_SOP.pdf` |

### Line-C · Welding & Assembly

| Station | Fault types | SOP |
|---|---|---|
| Component-Loader | `Feed-Jam`, `Sensor-Block`, `Hopper-Empty` | `Line-C_01_Component-Loader_SOP.pdf` |
| Welding-Robot | `Wire-Feed-Jam`, `Tip-Wear`, `Gas-Flow-Low` | `Line-C_02_Welding-Robot_SOP.pdf` |
| Weld-Inspection | `X-Ray-Tube-Fault`, `Calibration`, `Film-Jam` | `Line-C_03_Weld-Inspection_NDT.pdf` |
| Fastening-Station | `Torque-Drift`, `Bit-Break`, `Feeder-Jam` | `Line-C_04_Fastening-Station_SOP.pdf` |
| Assembly-Robot | `Joint-Calibration`, `Gripper-Fail`, `Encoder-Fault` | `Line-C_05_Assembly-Robot_SOP.pdf` |
| Leak-Test | `Pressure-Sensor`, `Seal-Wear`, `Valve-Stuck` | `Line-C_06_Leak-Test_SOP.pdf` |

### Line-D · Surface Treatment

| Station | Fault types | SOP |
|---|---|---|
| Surface-Prep | `Abrasive-Wear`, `Motor-Fault`, `Dust-Overload` | `Line-D_01_Surface-Prep_SOP.pdf` |
| Chemical-Wash | `Solution-Low`, `Pump-Fail`, `Temp-Drift` | `Line-D_02_Chemical-Wash_SOP.pdf` |
| Primer-Application | `Nozzle-Clog`, `Pressure-Drop`, `Viscosity-Off` | `Line-D_03_Primer-Application_SOP.pdf` |
| Paint-Booth | `Nozzle-Clog`, `Air-Filter-Saturated`, `Paint-Viscosity-Drift` | `Line-D_04_Paint-Booth_SOP.pdf` |
| Curing-Oven | `Thermocouple-Drift`, `Door-Seal-Worn`, `Element-Burnout` | `Line-D_05_Curing-Oven_SOP.pdf` |
| Coating-Inspection | `Camera-Fault`, `Light-Fail`, `Sensor-Drift` | `Line-D_06_Coating-Inspection_SOP.pdf` |
| Final-Packaging | `Conveyor-Jam`, `Seal-Bar-Temp`, `Film-Feed-Error` | `Line-D_07_Final-Packaging_SOP.pdf` |

### Line-E · Electronics Assembly

| Station | Fault types | SOP |
|---|---|---|
| PCB-Loader | `Feed-Jam`, `Magazine-Empty`, `Sensor-Block` | `Line-E_01_PCB-Loader_SOP.pdf` |
| SMT-Placement | `Nozzle-Clog`, `Feeder-Jam`, `Vision-Fail` | `Line-E_02_SMT-Placement_SOP.pdf` |
| Reflow-Oven | `Temp-Drift`, `Conveyor-Slip`, `Element-Fail` | `Line-E_03_Reflow-Oven_SOP.pdf` |
| AOI-Inspection | `Camera-Fault`, `Light-Fail`, `Calibration-Drift` | `Line-E_04_AOI-Inspection_SOP.pdf` |
| Through-Hole-Insert | `Lead-Bend`, `Insertion-Miss`, `Clinch-Fail` | `Line-E_05_Through-Hole-Insert_SOP.pdf` |
| Wave-Solder | `Solder-Temp-Drift`, `Flux-Low`, `Conveyor-Speed-Fault` | `Line-E_06_Wave-Solder_Troubleshooting.pdf` |
| Functional-Test | `Fixture-Fault`, `Probe-Wear`, `Power-Supply-Fail` | `Line-E_07_Functional-Test_SOP.pdf` |
| Conformal-Coat | `Nozzle-Clog`, `Viscosity-Off`, `UV-Lamp-Fail` | `Line-E_08_Conformal-Coat_SOP.pdf` |

## 4. Work-order lifecycle

When a station transitions to `Fault`, the system creates a maintenance
work order with the following states:

1. **Open** — work order created when the fault is detected. The station's
   `machine_status` transitions to `Fault`.
2. **Acknowledged** — technician has accepted the work order. Acknowledge
   delay target: **30–120 s** (`acknowledgeDelay` in simulator config).
3. **In Progress** — technician is on the station performing repair.
   In-progress delay target: **60–300 s**.
4. **Resolved** — work order closed. The station transitions to
   `Maintenance` for the resolve delay (**120–600 s**) and then back to
   `Running`.

There are **8 technicians on shift** (IDs `T001` through `T008`). Work
orders are dispatched to the first available technician.

## 5. Escalation triggers

- Two or more open work orders on the same line at the same time →
  notify the Line Manager.
- A station exceeds **3 faults in any 60-minute window** → notify the
  Maintenance Lead and add the station to the priority PM list.
- Line OEE drops below 60 % for **> 15 minutes** → escalate per
  `OEE_Targets_and_Escalation.pdf`.

## 6. References

- `Safety_Lockout_Tagout_Procedure.pdf` — LOTO is required for every
  `Maintenance` action that opens an enclosure or exposes energy.
- `Quality_Reject_Disposition_Policy.pdf` — handling of parts produced
  during the cycles immediately preceding a fault.
- `OEE_Targets_and_Escalation.pdf` — KPI thresholds.
- `Shift_Handover_Checklist.pdf` — open work orders are a mandatory
  handover topic.
- `Production_Lines_Reference.pdf` — line topology and bottleneck stations.
