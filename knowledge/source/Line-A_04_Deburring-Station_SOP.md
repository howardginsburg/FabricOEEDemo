---
title: "Deburring-Station — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-A"
station_position: 4
station_type: "Deburring-Station"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Deburring-Station — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-A, station 4, Deburring-Station

## 1. Purpose

The Deburring-Station removes machining burrs and sharp edges left by the
mill and grinder before final dimensional verification at CMM-Inspection. A
deburring stoppage starves the CMM and blocks the grinder.

## 2. Normal operating envelope

- Ideal cycle time: **15 s**
- Max acceptable cycle time: **20 s**
- Expected reject rate: **≤ 1 %**
- Fault probability per cycle: **0.2 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Surface-Grinder (station 3) is not feeding parts. | Verify grinder state. |
| `Blocked` | CMM-Inspection (station 5) buffer is full. | Verify CMM state. |

## 4. Faults & corrective actions

### 4.1 `Brush-Wear`

- **Symptoms in telemetry:** `fault_type = "Brush-Wear"`. CMM begins
  flagging residual burrs as quality rejects.
- **Likely root cause:** wire/bristle brushes worn below service length.
- **Corrective action:**
  1. LOTO. Remove the worn brush assembly.
  2. Install a new brush set; verify free length within OEM spec.
  3. Set spindle speed per the parts being run.
- **Restart criteria:** three parts pass CMM edge-break inspection in a
  row.

### 4.2 `Motor-Overheat`

- **Symptoms in telemetry:** `fault_type = "Motor-Overheat"`. Often follows
  a stretch with elevated cycle times that pushed the duty cycle.
- **Likely root cause:** clogged cooling fan inlet, ambient over-temperature,
  or worn brushes raising current draw.
- **Corrective action:**
  1. LOTO and allow the motor to cool below 60 °C.
  2. Clean fan inlet; inspect ducting for blockage.
  3. Check stator current at no-load; replace motor if outside spec.
- **Restart criteria:** stable motor temperature across 10 minutes of run.

### 4.3 `Jam`

- **Symptoms in telemetry:** `fault_type = "Jam"`. Conveyor stops; upstream
  blocks within minutes.
- **Likely root cause:** part misalignment in the fixture or a foreign
  object in the deburr cell.
- **Corrective action:**
  1. LOTO. Remove the jammed part and any debris.
  2. Inspect the fixture jaws and conveyor guides.
  3. Cycle the empty fixture three times to confirm clearance.
- **Restart criteria:** clean test cycle, no contact alarms.

## 5. Preventive maintenance schedule

- **Daily:** clear chip tray; visual brush check.
- **Weekly:** lubricate conveyor chain; check fixture wear pads.
- **Monthly:** replace brushes; clean motor cooling inlet.
- **Quarterly:** motor brushgear inspection.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-A_03_Surface-Grinder_SOP.pdf`
- `Line-A_05_CMM-Inspection_Calibration.pdf`
