---
title: "CNC-Mill — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-A"
station_position: 2
station_type: "CNC-Mill"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# CNC-Mill — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-A, station 2, CNC-Mill

## 1. Purpose

The CNC-Mill is the second station of Line-A. It receives a turned shaft
blank from the CNC-Lathe and machines keyways, flats, and feature pockets
into it before the part moves to the Surface-Grinder. A mill outage cascades
quickly: the upstream lathe blocks within one buffer fill, and downstream
grinders, deburring, and CMM all starve.

## 2. Normal operating envelope

- Ideal cycle time: **45 s**
- Max acceptable cycle time: **54 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.8 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning on the CNC-Mill | First check |
|---|---|---|
| `Starved` | CNC-Lathe (station 1) is not feeding parts. | Inspect the lathe's status (`Fault`, `Maintenance`, or also `Idle`). |
| `Blocked` | Surface-Grinder (station 3) output buffer is full. | Resolve the grinder's downstream condition first. |

## 4. Faults & corrective actions

### 4.1 `Spindle-Vibration`

- **Symptoms in telemetry:** `fault_type = "Spindle-Vibration"`; reject rate
  trends above 3 % in the hour leading up to the fault.
- **Likely root cause:** spindle imbalance, worn tool holder, or loose
  drawbar.
- **Corrective action:**
  1. LOTO and isolate spindle drive.
  2. Inspect drawbar tension; re-torque to OEM spec.
  3. Replace the tool holder; rebalance the spindle assembly.
  4. Run a 30-second air-cut diagnostic and record vibration amplitude.
- **Restart criteria:** vibration amplitude < 0.5 mm/s RMS at idle.

### 4.2 `Coolant-Leak`

- **Symptoms in telemetry:** `fault_type = "Coolant-Leak"`; operators may
  also report a visual puddle around the enclosure.
- **Likely root cause:** failed enclosure seal, cracked hose, or
  loose flood-coolant fitting.
- **Corrective action:**
  1. LOTO and drain the coolant tank.
  2. Trace the leak; replace the failed seal, hose, or fitting.
  3. Refill coolant to spec concentration (5–8 % emulsion).
  4. Run a 5-minute leak test before resuming.
- **Restart criteria:** no visible leak across a 5-minute idle test.

### 4.3 `Tool-Wear`

- **Symptoms in telemetry:** `fault_type = "Tool-Wear"`. May be preceded by
  rising actual cycle time and increasing reject rate, particularly with
  surface finish callouts at CMM-Inspection.
- **Likely root cause:** insert end of service life; aggressive feed.
- **Corrective action:**
  1. Index the worn tool out of service.
  2. Install fresh insert; reset tool offset against the probe.
  3. Re-inspect any parts machined in the prior 10 cycles at CMM.
- **Restart criteria:** tool offset within 0.005 mm of master.

## 5. Preventive maintenance schedule

- **Daily:** check coolant concentration; clear chip evacuation auger.
- **Weekly:** spindle drawbar torque check; air-blow tool changer.
- **Monthly:** way-cover inspection; replace coolant filter.
- **Quarterly:** spindle vibration analysis; ATC mechanical service.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Quality_Reject_Disposition_Policy.pdf`
- `Line-A_01_CNC-Lathe_SOP.pdf`
- `Line-A_03_Surface-Grinder_SOP.pdf`
