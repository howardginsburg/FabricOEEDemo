---
title: "Paint-Booth — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-D"
station_position: 4
station_type: "Paint-Booth"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Paint-Booth — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-D, station 4, Paint-Booth

## 1. Purpose

The Paint-Booth applies the finish topcoat via electrostatic or robotic
spray. It feeds the Curing-Oven (Line-D's bottleneck), so a paint outage
quickly back-fills the booth-side buffer and blocks Primer-Application.

## 2. Normal operating envelope

- Ideal cycle time: **40 s**
- Max acceptable cycle time: **52 s**
- Expected reject rate: **≤ 4 %**
- Fault probability per cycle: **0.8 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Primer-Application (station 3) is not feeding parts. | Verify Primer-Application state. |
| `Blocked` | Curing-Oven (station 5) cannot accept the painted part. | Verify Curing-Oven state — this is the line bottleneck. |

## 4. Faults & corrective actions

### 4.1 `Nozzle-Clog`

- **Symptoms in telemetry:** `fault_type = "Nozzle-Clog"`. Pattern
  asymmetric; coating thickness rejects rise.
- **Likely root cause:** dried paint in the gun tip; supply contamination.
- **Corrective action:**
  1. Purge gun with solvent; clean tip.
  2. Inspect supply filter; replace if loaded.
- **Restart criteria:** pattern matches reference card.

### 4.2 `Air-Filter-Saturated`

- **Symptoms in telemetry:** `fault_type = "Air-Filter-Saturated"`. Booth
  airflow drops; overspray accumulates on parts.
- **Likely root cause:** intake or exhaust filter loaded with paint solids
  past service interval.
- **Corrective action:**
  1. LOTO. Replace saturated filters.
  2. Verify booth pressure differential.
- **Restart criteria:** airflow within spec.

### 4.3 `Paint-Viscosity-Drift`

- **Symptoms in telemetry:** `fault_type = "Paint-Viscosity-Drift"`. Coating
  thickness variable; orange peel appearance.
- **Likely root cause:** solvent evaporation in the supply pot, or batch out
  of spec.
- **Corrective action:**
  1. Sample paint; measure viscosity.
  2. Adjust thinner to recipe.
  3. Re-validate against the test card.
- **Restart criteria:** viscosity within recipe range.

## 5. Preventive maintenance schedule

- **Daily:** gun purge; viscosity check.
- **Weekly:** filter inspection; booth pressure check.
- **Monthly:** filter changeout.
- **Quarterly:** full atomization-system service.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-D_03_Primer-Application_SOP.pdf`
- `Line-D_05_Curing-Oven_SOP.pdf`
- `Line-D_06_Coating-Inspection_SOP.pdf`
