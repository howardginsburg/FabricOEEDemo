---
title: "Coating-Inspection — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-D"
station_position: 6
station_type: "Coating-Inspection"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# Coating-Inspection — Standard Operating Procedure

> **Audience:** Quality Worker · Maintenance Tech · Line Manager
> **Applies to:** Line-D, station 6, Coating-Inspection

## 1. Purpose

Coating-Inspection verifies finish quality (thickness, color, surface
defects) on every cured part before Final-Packaging. Reject disposition
follows `Quality_Reject_Disposition_Policy.pdf`.

## 2. Normal operating envelope

- Ideal cycle time: **15 s**
- Max acceptable cycle time: **20 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.2 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Curing-Oven (station 5) is not feeding parts. | Verify Curing-Oven state — the line bottleneck. |
| `Blocked` | Final-Packaging (station 7) cannot accept the part. | Verify Final-Packaging state. |

## 4. Faults & corrective actions

### 4.1 `Camera-Fault`

- **Symptoms in telemetry:** `fault_type = "Camera-Fault"`. Inspection
  cycle aborts or rejects spike with vision-system codes.
- **Likely root cause:** lens fouled, focus drifted, or camera controller
  failure.
- **Corrective action:**
  1. Clean lens; check focus.
  2. Cycle camera power.
  3. Replace camera if image acquisition still fails.
- **Restart criteria:** master part passes vision recipe.

### 4.2 `Light-Fail`

- **Symptoms in telemetry:** `fault_type = "Light-Fail"`. Image contrast
  drops; rejects surge.
- **Likely root cause:** light bar driver failed or LED bank ended life.
- **Corrective action:**
  1. LOTO. Replace failed light.
  2. Restore brightness setpoint.
- **Restart criteria:** image meets contrast threshold.

### 4.3 `Sensor-Drift`

- **Symptoms in telemetry:** `fault_type = "Sensor-Drift"`. False-positive
  rejects rise; thickness gauge readings vary.
- **Likely root cause:** thickness gauge calibration drift or temperature
  effects.
- **Corrective action:**
  1. Run calibration routine against master step block.
  2. Replace sensor if out of spec.
- **Restart criteria:** calibration error within ± 2 μm.

## 5. Preventive maintenance schedule

- **Daily:** wipe lenses; run master parts at shift start.
- **Weekly:** clean diffusers.
- **Monthly:** thickness gauge calibration.
- **Quarterly:** lighting replacement.

## 6. References

- `Quality_Reject_Disposition_Policy.pdf`
- `Maintenance_Workflow_Overview.pdf`
- `Shift_Handover_Checklist.pdf`
- `Line-D_05_Curing-Oven_SOP.pdf`
- `Line-D_07_Final-Packaging_SOP.pdf`
