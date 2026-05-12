---
title: "Primer-Application — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-D"
station_position: 3
station_type: "Primer-Application"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Primer-Application — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-D, station 3, Primer-Application

## 1. Purpose

Primer-Application sprays a primer coat onto the washed part to promote
adhesion of the topcoat applied at the Paint-Booth.

## 2. Normal operating envelope

- Ideal cycle time: **25 s**
- Max acceptable cycle time: **33 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.5 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Chemical-Wash (station 2) is not feeding parts. | Verify Chemical-Wash state. |
| `Blocked` | Paint-Booth (station 4) cannot accept the primed part. | Verify Paint-Booth state. |

## 4. Faults & corrective actions

### 4.1 `Nozzle-Clog`

- **Symptoms in telemetry:** `fault_type = "Nozzle-Clog"`. Spray fan
  asymmetric; thickness rejects rise at Coating-Inspection.
- **Likely root cause:** dried primer in the nozzle from a prolonged idle
  period; foreign matter in the supply line.
- **Corrective action:**
  1. Flush the nozzle with solvent.
  2. If still clogged, remove and clean nozzle in ultrasonic bath.
- **Restart criteria:** spray pattern verified against the test pattern card.

### 4.2 `Pressure-Drop`

- **Symptoms in telemetry:** `fault_type = "Pressure-Drop"`. Coating
  thickness drops out of spec.
- **Likely root cause:** supply pump failing or air-assist regulator drift.
- **Corrective action:**
  1. Verify air pressure at the gun.
  2. Inspect supply pump output.
- **Restart criteria:** stable atomization pressure for 5 minutes.

### 4.3 `Viscosity-Off`

- **Symptoms in telemetry:** `fault_type = "Viscosity-Off"`. Coating
  thickness highly variable; downstream Coating-Inspection rejects mixed.
- **Likely root cause:** primer batch out of spec, or thinner ratio drifted.
- **Corrective action:**
  1. Sample primer; measure with the viscosity cup.
  2. Adjust thinner to recipe.
  3. Re-validate against the spray test card.
- **Restart criteria:** viscosity within ± 2 s of recipe.

## 5. Preventive maintenance schedule

- **Daily:** purge gun at shutdown; check viscosity at startup.
- **Weekly:** clean nozzles; check filters.
- **Monthly:** supply pump service.
- **Quarterly:** full atomization-system tune.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Line-D_02_Chemical-Wash_SOP.pdf`
- `Line-D_04_Paint-Booth_SOP.pdf`
- `Line-D_06_Coating-Inspection_SOP.pdf`
