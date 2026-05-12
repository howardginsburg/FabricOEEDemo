---
title: "Curing-Oven — Standard Operating Procedure (Line-D Bottleneck)"
doc_type: "Standard Operating Procedure"
line_id: "Line-D"
station_position: 5
station_type: "Curing-Oven"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Curing-Oven — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-D, station 5, Curing-Oven

## 1. Purpose

The Curing-Oven heat-cures the topcoat on every painted part. With a **90 s
ideal cycle time**, this is the slowest station on the factory floor and
the **bottleneck of Line-D** — any further slowdown immediately caps line
throughput. Painted parts back up in the booth buffer if the oven slows or
stops.

## 2. Normal operating envelope

- Ideal cycle time: **90 s** (line bottleneck)
- Max acceptable cycle time: **110 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.6 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Paint-Booth (station 4) is not feeding parts. | Verify Paint-Booth state. |
| `Blocked` | Coating-Inspection (station 6) cannot accept cured parts. | Verify Coating-Inspection state. |

Because this is the bottleneck, watching for **rising actual cycle time
without a `Fault` yet raised** is the leading indicator of a brewing problem.

## 4. Faults & corrective actions

### 4.1 `Thermocouple-Drift`

- **Symptoms in telemetry:** `fault_type = "Thermocouple-Drift"`. Cure
  profile out of spec; downstream Coating-Inspection rejects rise.
- **Likely root cause:** thermocouple junction degraded after long service.
- **Corrective action:**
  1. Verify thermocouple against a master probe.
  2. Replace the thermocouple; re-validate cure profile.
- **Restart criteria:** profile within ± 5 °C across the zones.

### 4.2 `Door-Seal-Worn`

- **Symptoms in telemetry:** `fault_type = "Door-Seal-Worn"`. Heat loss;
  cycle time grows toward 110 s as the oven struggles to hold setpoint.
- **Likely root cause:** door gasket compressed or torn.
- **Corrective action:**
  1. LOTO. Replace the door gasket.
  2. Verify door closing pressure.
- **Restart criteria:** stable setpoint at rated cycle.

### 4.3 `Element-Burnout`

- **Symptoms in telemetry:** `fault_type = "Element-Burnout"`. One or more
  zones fall short of setpoint; oven trips on under-temperature.
- **Likely root cause:** heating element failed open.
- **Corrective action:**
  1. LOTO. Diagnose the failed zone (resistance check).
  2. Replace the element.
  3. Validate the cure profile against the recipe.
- **Restart criteria:** zone temperatures balanced; profile within ± 5 °C.

## 5. Preventive maintenance schedule

- **Daily:** record cure profile from the trend chart.
- **Weekly:** inspect door seal; clean conveyor.
- **Monthly:** thermocouple verification against master.
- **Quarterly:** element resistance check; bake out residue.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `OEE_Targets_and_Escalation.pdf`
- `Line-D_04_Paint-Booth_SOP.pdf`
- `Line-D_06_Coating-Inspection_SOP.pdf`
