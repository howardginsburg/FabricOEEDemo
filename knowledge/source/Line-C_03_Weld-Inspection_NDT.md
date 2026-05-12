---
title: "Weld-Inspection — NDT Procedure"
doc_type: "Non-Destructive Testing Procedure"
line_id: "Line-C"
station_position: 3
station_type: "Weld-Inspection"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# Weld-Inspection — Non-Destructive Testing (NDT) Procedure

> **Audience:** Quality Worker (primary) · Maintenance Tech · Line Manager
> **Applies to:** Line-C, station 3, Weld-Inspection

## 1. Purpose

Weld-Inspection performs non-destructive testing (X-ray and ultrasonic) on
every welded subassembly leaving station 2. This station has the most
varied reject codes on Line-C and gates parts before Fastening at
station 4. Reject disposition follows
`Quality_Reject_Disposition_Policy.pdf`.

## 2. Normal operating envelope

- Ideal cycle time: **30 s**
- Max acceptable cycle time: **38 s**
- Expected reject rate: **≤ 4 %**
- Fault probability per cycle: **0.5 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Welding-Robot (station 2) is not feeding parts. | Verify Welding-Robot state. |
| `Blocked` | Fastening-Station (station 4) cannot accept the inspected part. | Verify Fastening state. |

## 4. Faults & corrective actions

### 4.1 `X-Ray-Tube-Fault`

- **Symptoms in telemetry:** `fault_type = "X-Ray-Tube-Fault"`. Image quality
  drops or imaging stops; reject rate may swing wildly.
- **Likely root cause:** X-ray tube reached end of life, or high-voltage
  arc-over.
- **Corrective action:**
  1. Lock out the X-ray cabinet per radiation safety.
  2. Verify HV power supply readings; replace the tube if filament is
     open.
  3. Run image quality indicator (IQI) test pieces.
- **Restart criteria:** IQI sensitivity meets the spec written on the recipe.

### 4.2 `Calibration`

- **Symptoms in telemetry:** `fault_type = "Calibration"`. Inspection
  reports either no defects ever or every part rejected.
- **Likely root cause:** automatic defect classifier drift; recipe
  parameters out of range.
- **Corrective action:**
  1. Run the calibration set (known-defect + known-good parts).
  2. Tune sensitivity until both pass and reject thresholds are met.
  3. Sign off recipe revision in the QMS.
- **Restart criteria:** 100 % accuracy on the calibration set.

### 4.3 `Film-Jam`

- **Symptoms in telemetry:** `fault_type = "Film-Jam"`. Inspection cycle
  cannot complete.
- **Likely root cause:** legacy radiographic media handler jammed (where
  applicable), or detector-panel transport stuck.
- **Corrective action:**
  1. LOTO. Clear the jam.
  2. Inspect transport rollers; replace worn ones.
  3. Verify panel positioning against the master target.
- **Restart criteria:** transport cycles 10 times with no slip.

## 5. Preventive maintenance schedule

- **Daily:** IQI verification at shift start.
- **Weekly:** detector clean; transport rollers inspected.
- **Monthly:** radiation safety integrity test.
- **Quarterly:** classifier retraining against the latest accepted defects.

## 6. References

- `Quality_Reject_Disposition_Policy.pdf`
- `Maintenance_Workflow_Overview.pdf`
- `Line-C_02_Welding-Robot_SOP.pdf`
- `Line-C_04_Fastening-Station_SOP.pdf`
