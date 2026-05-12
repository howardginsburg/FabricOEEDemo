---
title: "Final-Packaging — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-D"
station_position: 7
station_type: "Final-Packaging"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Final-Packaging — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-D, station 7, Final-Packaging

## 1. Purpose

Final-Packaging is the last station of Line-D. It wraps and boxes finished
parts for shipment. A stoppage here blocks upstream Coating-Inspection
within one buffer fill (≈ 10 seconds).

## 2. Normal operating envelope

- Ideal cycle time: **10 s**
- Max acceptable cycle time: **14 s**
- Expected reject rate: **0 %**
- Fault probability per cycle: **0.1 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Coating-Inspection (station 6) is not feeding parts. | Verify Coating-Inspection state. |
| `Blocked` | Outbound shipping dock conveyor full. | Verify discharge conveyor. |

## 4. Faults & corrective actions

### 4.1 `Conveyor-Jam`

- **Symptoms in telemetry:** `fault_type = "Conveyor-Jam"`. Packaging halts;
  upstream blocks.
- **Likely root cause:** part misalignment, foreign object, or torn belt.
- **Corrective action:**
  1. LOTO. Clear the jam.
  2. Inspect belt for damage; replace if torn.
- **Restart criteria:** 20 cycles without slip.

### 4.2 `Seal-Bar-Temp`

- **Symptoms in telemetry:** `fault_type = "Seal-Bar-Temp"`. Heat sealer
  out of temperature range; seal quality alarms.
- **Likely root cause:** heating element degraded; thermocouple drift.
- **Corrective action:**
  1. LOTO. Verify element resistance.
  2. Replace element or thermocouple.
- **Restart criteria:** stable seal temperature ± 3 °C.

### 4.3 `Film-Feed-Error`

- **Symptoms in telemetry:** `fault_type = "Film-Feed-Error"`. Wrap film not
  advancing.
- **Likely root cause:** film roll empty, film tear, or feed roller slipping.
- **Corrective action:**
  1. Replace film roll if exhausted.
  2. Re-thread film; verify tension.
  3. Clean feed rollers.
- **Restart criteria:** continuous feed for 5 cycles.

## 5. Preventive maintenance schedule

- **Daily:** clean seal bar; check film stock.
- **Weekly:** belt tracking; clean feed rollers.
- **Monthly:** seal bar element check.
- **Quarterly:** full conveyor lubrication.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Line-D_06_Coating-Inspection_SOP.pdf`
- `Production_Lines_Reference.pdf`
