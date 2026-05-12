---
title: "Chemical-Wash — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-D"
station_position: 2
station_type: "Chemical-Wash"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Chemical-Wash — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-D, station 2, Chemical-Wash

## 1. Purpose

Chemical-Wash removes oils, residues, and abrasive dust from the
Surface-Prep'd part before primer application. Solution chemistry control
is critical to downstream paint adhesion.

## 2. Normal operating envelope

- Ideal cycle time: **30 s**
- Max acceptable cycle time: **38 s**
- Expected reject rate: **≤ 1 %**
- Fault probability per cycle: **0.4 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Surface-Prep (station 1) is not feeding parts. | Verify Surface-Prep state. |
| `Blocked` | Primer-Application (station 3) cannot accept the washed part. | Verify Primer-Application state. |

## 4. Faults & corrective actions

### 4.1 `Solution-Low`

- **Symptoms in telemetry:** `fault_type = "Solution-Low"`. Wash quality
  drops; paint-adhesion rejects climb at Coating-Inspection.
- **Likely root cause:** wash tank level below the suction-line minimum
  due to evaporation, drag-out, or unscheduled drain.
- **Corrective action:**
  1. Refill the wash tank with deionized make-up water and chemistry.
  2. Verify pH and conductivity per recipe.
- **Restart criteria:** chemistry within recipe limits.

### 4.2 `Pump-Fail`

- **Symptoms in telemetry:** `fault_type = "Pump-Fail"`. Spray pressure drops
  to zero; wash quality nil.
- **Likely root cause:** pump motor trip, mechanical seal failure, or
  impeller wear.
- **Corrective action:**
  1. LOTO. Diagnose mechanical vs. electrical.
  2. Replace seal kit or motor as needed.
- **Restart criteria:** spray pressure within recipe.

### 4.3 `Temp-Drift`

- **Symptoms in telemetry:** `fault_type = "Temp-Drift"`. Bath temperature
  out of range affects cleaning efficacy.
- **Likely root cause:** immersion heater element failed, thermostat drift,
  or heat exchanger fouled.
- **Corrective action:**
  1. Verify element current draw.
  2. Replace failed element; verify thermocouple.
- **Restart criteria:** stable bath temperature ± 2 °C.

## 5. Preventive maintenance schedule

- **Daily:** check pH, conductivity, tank level.
- **Weekly:** clean spray nozzles.
- **Monthly:** chemistry change-out per recipe schedule.
- **Quarterly:** heat exchanger service.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Line-D_01_Surface-Prep_SOP.pdf`
- `Line-D_03_Primer-Application_SOP.pdf`
