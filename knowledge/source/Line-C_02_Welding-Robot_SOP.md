---
title: "Welding-Robot — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-C"
station_position: 2
station_type: "Welding-Robot"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Welding-Robot — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-C, station 2, Welding-Robot

## 1. Purpose

The Welding-Robot performs MIG / TIG robotic welds joining the components
delivered by the loader. It is the second-highest fault contributor on
Line-C (after Leak-Test) and a key driver of weld-related rejects at
Weld-Inspection.

## 2. Normal operating envelope

- Ideal cycle time: **25 s**
- Max acceptable cycle time: **32 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.7 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Component-Loader (station 1) is not feeding parts. | Verify Component-Loader state. |
| `Blocked` | Weld-Inspection (station 3) cannot accept the welded part. | Verify Weld-Inspection state. |

## 4. Faults & corrective actions

### 4.1 `Wire-Feed-Jam`

- **Symptoms in telemetry:** `fault_type = "Wire-Feed-Jam"`. Arc fails mid-
  cycle; Weld-Inspection (next station) flags missing welds.
- **Likely root cause:** wire snagged in the liner, drive rolls worn, or
  spool brake too tight.
- **Corrective action:**
  1. LOTO. Open the wire-feed drive.
  2. Clear the snagged wire; trim and reload through the liner.
  3. Inspect drive rolls; replace if grooved.
- **Restart criteria:** three test welds pass visual and CT contour check.

### 4.2 `Tip-Wear`

- **Symptoms in telemetry:** `fault_type = "Tip-Wear"`. Erratic arc start;
  porosity rejects flagged at Weld-Inspection.
- **Likely root cause:** contact tip bore worn beyond service limit.
- **Corrective action:**
  1. LOTO. Replace the contact tip; inspect the gas diffuser.
  2. Verify wire stick-out per recipe.
- **Restart criteria:** five welds with stable arc current trace.

### 4.3 `Gas-Flow-Low`

- **Symptoms in telemetry:** `fault_type = "Gas-Flow-Low"`. Porosity defects
  cluster on Weld-Inspection.
- **Likely root cause:** shielding-gas regulator drifted, hose leak, or
  cylinder near-empty.
- **Corrective action:**
  1. Verify cylinder pressure and flow at the torch.
  2. Leak-check hose connections with soapy water.
  3. Replace regulator if it cannot hold setpoint.
- **Restart criteria:** flow stable at 15–20 L/min for 5 minutes.

## 5. Preventive maintenance schedule

- **Daily:** check wire-feed tension; gas-flow readback.
- **Weekly:** replace contact tip; clean nozzle.
- **Monthly:** robot path verification; cable management check.
- **Quarterly:** robot axis backlash measurement.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-C_01_Component-Loader_SOP.pdf`
- `Line-C_03_Weld-Inspection_NDT.pdf`
