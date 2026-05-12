---
title: "CMM-Inspection — Calibration & Operating Procedure"
doc_type: "Calibration Procedure"
line_id: "Line-A"
station_position: 5
station_type: "CMM-Inspection"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# CMM-Inspection — Calibration & Operating Procedure

> **Audience:** Maintenance Tech · Quality Worker · Line Manager
> **Applies to:** Line-A, station 5, CMM-Inspection (Coordinate Measuring Machine)

## 1. Purpose

CMM-Inspection is the final station of Line-A and the quality gate for the
entire precision machining cell. It verifies dimensional tolerances on every
part before release. Because its ideal cycle time (60 s) is the longest on
the line, it is the **bottleneck** — any extra delay here directly caps
line throughput and pushes blocked state back through stations 1–4.

## 2. Normal operating envelope

- Ideal cycle time: **60 s** (bottleneck)
- Max acceptable cycle time: **72 s**
- Expected reject rate: **≤ 5 %**
- Fault probability per cycle: **0.4 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Deburring-Station (station 4) is not feeding parts. | Verify deburring state. |
| `Blocked` | Final part-out conveyor is full. | Verify the line discharge. |

## 4. Faults & corrective actions

### 4.1 `Probe-Calibration`

- **Symptoms in telemetry:** `fault_type = "Probe-Calibration"`. Rejects
  often jump just before the fault as the probe drifts.
- **Likely root cause:** probe stylus is bent, cross-axis ruby has worn, or
  thermal drift has shifted the touch trigger force.
- **Corrective action:**
  1. Run the **probe qualification cycle** against the master sphere.
  2. If qualification error > 2 μm, replace the stylus and re-qualify.
  3. Reset the part coordinate frame using the alignment datum holes.
- **Restart criteria:** master sphere qualification error ≤ 2 μm.

### 4.2 `Air-Supply`

- **Symptoms in telemetry:** `fault_type = "Air-Supply"`. CMM bearings are
  air-bearing — without supply the machine cannot home.
- **Likely root cause:** compressed air pressure dropped below 80 psi at the
  CMM inlet, or air dryer failure produced moisture trip.
- **Corrective action:**
  1. Confirm shop-air pressure at the CMM regulator; target 90 psi.
  2. Check the inlet filter / dryer; drain condensate trap.
  3. If the dryer tripped, allow recovery before re-energizing.
- **Restart criteria:** stable 90 ± 5 psi for 5 minutes with no moisture
  alarm.

### 4.3 `Sensor-Fail`

- **Symptoms in telemetry:** `fault_type = "Sensor-Fail"`. CMM may home
  short, drop axes, or report touch-misses on a known-good part.
- **Likely root cause:** scale read-head failure or probe interface cable
  intermittent.
- **Corrective action:**
  1. Cycle CMM power; check error log for axis fault codes.
  2. Inspect read-head cables for damage; reseat at controller.
  3. Replace the failed read-head; recalibrate that axis.
- **Restart criteria:** axis accuracy check passes within 2 μm.

## 5. Preventive maintenance schedule

- **Daily:** thermal soak (CMM must run for 30 minutes before inspection
  starts on a cold morning).
- **Weekly:** clean granite table; check air filter; run probe
  qualification.
- **Monthly:** full ball-bar test; replace air dryer desiccant.
- **Annually:** ISO 10360 volumetric accuracy certification by an external
  calibration lab.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Quality_Reject_Disposition_Policy.pdf`
- `Line-A_04_Deburring-Station_SOP.pdf`
- `Production_Lines_Reference.pdf`
