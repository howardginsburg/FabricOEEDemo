---
title: "AOI-Inspection — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-E"
station_position: 4
station_type: "AOI-Inspection"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# AOI-Inspection — Standard Operating Procedure

> **Audience:** Quality Worker · Maintenance Tech · Line Manager
> **Applies to:** Line-E, station 4, AOI-Inspection (Automated Optical Inspection)

## 1. Purpose

AOI-Inspection performs automated optical inspection of the soldered SMT
joints leaving Reflow-Oven. Reject disposition follows
`Quality_Reject_Disposition_Policy.pdf`.

## 2. Normal operating envelope

- Ideal cycle time: **10 s**
- Max acceptable cycle time: **14 s**
- Expected reject rate: **≤ 4 %**
- Fault probability per cycle: **0.3 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Reflow-Oven (station 3) is not feeding boards. | Verify Reflow-Oven state. |
| `Blocked` | Through-Hole-Insert (station 5) buffer full. | Verify Through-Hole-Insert state. |

## 4. Faults & corrective actions

### 4.1 `Camera-Fault`

- **Symptoms in telemetry:** `fault_type = "Camera-Fault"`. Inspection
  cycle aborts or image acquisition fails.
- **Likely root cause:** lens fouled, focus drifted, camera failure.
- **Corrective action:**
  1. Clean lens; cycle camera power.
  2. Replace camera if acquisition still fails.
- **Restart criteria:** master PCB passes recipe.

### 4.2 `Light-Fail`

- **Symptoms in telemetry:** `fault_type = "Light-Fail"`. Image contrast
  drops.
- **Likely root cause:** ring-light LED bank failed.
- **Corrective action:**
  1. LOTO. Replace the light bar.
  2. Restore brightness setpoint.
- **Restart criteria:** image meets contrast threshold.

### 4.3 `Calibration-Drift`

- **Symptoms in telemetry:** `fault_type = "Calibration-Drift"`. False-
  positive or false-negative rejects rise.
- **Likely root cause:** classifier drift; temperature-induced offset.
- **Corrective action:**
  1. Run the calibration set (known-good + known-defect PCBs).
  2. Tune thresholds; sign off recipe revision in the QMS.
- **Restart criteria:** 100 % accuracy on the calibration set.

## 5. Preventive maintenance schedule

- **Daily:** master PCB verification at shift start.
- **Weekly:** clean lenses and diffusers.
- **Monthly:** classifier retraining.
- **Quarterly:** lighting replacement.

## 6. References

- `Quality_Reject_Disposition_Policy.pdf`
- `Shift_Handover_Checklist.pdf`
- `Line-E_03_Reflow-Oven_SOP.pdf`
- `Line-E_05_Through-Hole-Insert_SOP.pdf`
