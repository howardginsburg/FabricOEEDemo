---
title: "Leak-Test — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-C"
station_position: 6
station_type: "Leak-Test"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# Leak-Test — Standard Operating Procedure

> **Audience:** Quality Worker · Maintenance Tech · Line Manager
> **Applies to:** Line-C, station 6, Leak-Test

## 1. Purpose

Leak-Test is the final station of Line-C. It pressurizes the assembled
subassembly and measures decay to detect any leak path that escaped earlier
inspection. Reject parts route to the policy in
`Quality_Reject_Disposition_Policy.pdf`.

## 2. Normal operating envelope

- Ideal cycle time: **25 s**
- Max acceptable cycle time: **32 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.6 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Assembly-Robot (station 5) is not feeding parts. | Verify Assembly-Robot state. |
| `Blocked` | Discharge conveyor full. | Verify part-out conveyor. |

## 4. Faults & corrective actions

### 4.1 `Pressure-Sensor`

- **Symptoms in telemetry:** `fault_type = "Pressure-Sensor"`. Inconsistent
  pressure decay readings; reject pattern shifts unpredictably.
- **Likely root cause:** sensor drift, calibration expired, or cable damaged.
- **Corrective action:**
  1. Verify sensor against a master gauge.
  2. If drift > 0.5 %, replace the sensor.
  3. Re-validate the recipe against the master leak.
- **Restart criteria:** test cycle passes the master leak (known leak) and
  the master pass (sealed) parts.

### 4.2 `Seal-Wear`

- **Symptoms in telemetry:** `fault_type = "Seal-Wear"`. False reject rate
  rises against parts that pass downstream verification.
- **Likely root cause:** fixture face seal hardened or cut after high cycle
  count.
- **Corrective action:**
  1. LOTO. Replace the fixture seal.
  2. Verify clamp force is to spec.
  3. Confirm zero-leak on the master pass part.
- **Restart criteria:** master pass part shows leak rate at noise floor.

### 4.3 `Valve-Stuck`

- **Symptoms in telemetry:** `fault_type = "Valve-Stuck"`. Pressurize or
  vent step times out.
- **Likely root cause:** solenoid valve coil burned, spool contaminated.
- **Corrective action:**
  1. LOTO. Replace the affected valve.
  2. Flush the air line.
- **Restart criteria:** pressure cycle completes within timing window.

## 5. Preventive maintenance schedule

- **Daily:** run master pass + master leak set at shift start.
- **Weekly:** inspect fixture seals.
- **Monthly:** sensor calibration verification.
- **Quarterly:** full pneumatic service.

## 6. References

- `Quality_Reject_Disposition_Policy.pdf`
- `Maintenance_Workflow_Overview.pdf`
- `Shift_Handover_Checklist.pdf`
- `Line-C_05_Assembly-Robot_SOP.pdf`
