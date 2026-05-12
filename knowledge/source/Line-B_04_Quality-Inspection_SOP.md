---
title: "Quality-Inspection — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-B"
station_position: 4
station_type: "Quality-Inspection"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# Quality-Inspection — Standard Operating Procedure

> **Audience:** Quality Worker · Maintenance Tech · Line Manager
> **Applies to:** Line-B, station 4, Quality-Inspection

## 1. Purpose

Quality-Inspection is the end-of-line gate for Line-B. A multi-camera
vision cell checks the trimmed housing for dimensional conformance,
surface defects, and missing features before the part is released for
shipment. Reject decisions follow `Quality_Reject_Disposition_Policy.pdf`.

## 2. Normal operating envelope

- Ideal cycle time: **20 s**
- Max acceptable cycle time: **26 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.2 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Trimming-Station (station 3) is not feeding parts. | Verify Trimming state — and back-check Hydraulic-Press at station 2. |
| `Blocked` | Discharge conveyor is full. | Verify the part-out conveyor. |

## 4. Faults & corrective actions

### 4.1 `Camera-Fault`

- **Symptoms in telemetry:** `fault_type = "Camera-Fault"`. Sudden spike in
  rejects with vision-system reason codes, or no image returned at all.
- **Likely root cause:** camera lens fouled, focus drifted, or camera
  controller communication dropped.
- **Corrective action:**
  1. Wipe lens; check for debris on the optical path.
  2. Cycle camera power; verify image acquisition in the diagnostic tool.
  3. If degraded, replace the camera; restore calibration from the saved
     recipe.
- **Restart criteria:** master part (known-good) passes inspection three
  times in a row.

### 4.2 `Sensor-Drift`

- **Symptoms in telemetry:** `fault_type = "Sensor-Drift"`. Rising false-
  reject rate against parts that pass downstream verification.
- **Likely root cause:** distance / proximity sensor calibration drift, or
  temperature-induced gain change.
- **Corrective action:**
  1. Run the calibration routine against the master gauge block.
  2. If still out of tolerance, replace the sensor.
  3. Re-verify all measurement features against the recipe.
- **Restart criteria:** calibration error within ± 0.02 mm.

### 4.3 `Light-Failure`

- **Symptoms in telemetry:** `fault_type = "Light-Failure"`. Vision system
  rejects increase; image histograms show low contrast.
- **Likely root cause:** ring-light LED failure or driver fault.
- **Corrective action:**
  1. LOTO and replace the failed light bar.
  2. Restore brightness setpoint per recipe.
  3. Re-validate against the master part.
- **Restart criteria:** master part image meets contrast threshold.

## 5. Preventive maintenance schedule

- **Daily:** wipe lenses; run master-part verification at shift start
  (see `Shift_Handover_Checklist.pdf`).
- **Weekly:** clean diffusers; check light driver currents.
- **Monthly:** full recipe revalidation against the gauge block.
- **Quarterly:** lighting replacement based on hours.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Quality_Reject_Disposition_Policy.pdf`
- `Shift_Handover_Checklist.pdf`
- `Line-B_03_Trimming-Station_SOP.pdf`
- `Production_Lines_Reference.pdf`
