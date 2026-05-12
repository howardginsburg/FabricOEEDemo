---
title: "Conformal-Coat — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-E"
station_position: 8
station_type: "Conformal-Coat"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Conformal-Coat — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-E, station 8, Conformal-Coat

## 1. Purpose

Conformal-Coat applies a thin protective polymer film over the tested
electronics module to shield it from moisture, contamination, and
vibration. UV cure follows the coating step. This is the final station of
Line-E.

## 2. Normal operating envelope

- Ideal cycle time: **25 s**
- Max acceptable cycle time: **32 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.4 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Functional-Test (station 7) is not feeding boards. | Verify Functional-Test state. |
| `Blocked` | Outbound conveyor full. | Verify part-out. |

## 4. Faults & corrective actions

### 4.1 `Nozzle-Clog`

- **Symptoms in telemetry:** `fault_type = "Nozzle-Clog"`. Coating pattern
  fails; thickness rejects rise.
- **Likely root cause:** dried coating in the nozzle from idle period.
- **Corrective action:**
  1. Flush with solvent.
  2. Clean nozzle in ultrasonic if needed.
- **Restart criteria:** spray pattern verified against the test card.

### 4.2 `Viscosity-Off`

- **Symptoms in telemetry:** `fault_type = "Viscosity-Off"`. Thickness highly
  variable; downstream inspection rejects clustering.
- **Likely root cause:** coating batch out of spec, or solvent evaporation.
- **Corrective action:**
  1. Sample coating; measure viscosity.
  2. Adjust thinner to recipe.
- **Restart criteria:** viscosity within recipe range.

### 4.3 `UV-Lamp-Fail`

- **Symptoms in telemetry:** `fault_type = "UV-Lamp-Fail"`. Cure
  incomplete; downstream stickiness rejects rise.
- **Likely root cause:** UV lamp at end of life, or driver failure.
- **Corrective action:**
  1. LOTO. Replace UV lamp.
  2. Verify UV intensity with radiometer.
- **Restart criteria:** UV dose within recipe range.

## 5. Preventive maintenance schedule

- **Daily:** purge gun; UV intensity check.
- **Weekly:** clean nozzle and lamps.
- **Monthly:** replace UV lamp at scheduled hours.
- **Quarterly:** atomization-system tune.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-E_07_Functional-Test_SOP.pdf`
- `Production_Lines_Reference.pdf`
