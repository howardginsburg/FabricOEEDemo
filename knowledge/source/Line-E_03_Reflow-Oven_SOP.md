---
title: "Reflow-Oven — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-E"
station_position: 3
station_type: "Reflow-Oven"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Reflow-Oven — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-E, station 3, Reflow-Oven

## 1. Purpose

The Reflow-Oven melts solder paste to bond SMT components placed by
SMT-Placement. A precise multi-zone temperature profile is essential to
joint quality. At 45 s ideal cycle, it is one of the longer steps on
Line-E.

## 2. Normal operating envelope

- Ideal cycle time: **45 s**
- Max acceptable cycle time: **55 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.4 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | SMT-Placement (station 2) is not feeding boards. | Verify SMT-Placement state. |
| `Blocked` | AOI-Inspection (station 4) cannot accept the soldered board. | Verify AOI-Inspection state. |

## 4. Faults & corrective actions

### 4.1 `Temp-Drift`

- **Symptoms in telemetry:** `fault_type = "Temp-Drift"`. Joint quality
  rejects rise at AOI; reject types cluster around cold-joint or solder-ball.
- **Likely root cause:** thermocouple drift, zone heater degraded.
- **Corrective action:**
  1. Profile against a Mole / data-logger.
  2. Calibrate or replace thermocouples.
  3. Replace failed heating zone if applicable.
- **Restart criteria:** profile within ± 5 °C of recipe across zones.

### 4.2 `Conveyor-Slip`

- **Symptoms in telemetry:** `fault_type = "Conveyor-Slip"`. PCBs do not
  travel through the oven at the right speed; thermal profile broken.
- **Likely root cause:** conveyor belt slippage, drive motor slowing.
- **Corrective action:**
  1. LOTO. Tension the conveyor.
  2. Inspect drive motor; replace if loaded.
- **Restart criteria:** consistent conveyor speed.

### 4.3 `Element-Fail`

- **Symptoms in telemetry:** `fault_type = "Element-Fail"`. One or more zones
  fall short of setpoint.
- **Likely root cause:** heating element failed open.
- **Corrective action:**
  1. LOTO. Resistance-check elements; replace the failed zone.
  2. Re-validate profile.
- **Restart criteria:** zone temperatures balanced.

## 5. Preventive maintenance schedule

- **Daily:** record profile.
- **Weekly:** clean conveyor and tunnel.
- **Monthly:** thermocouple verification.
- **Quarterly:** element check; conveyor service.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-E_02_SMT-Placement_SOP.pdf`
- `Line-E_04_AOI-Inspection_SOP.pdf`
