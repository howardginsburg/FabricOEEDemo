---
title: "Wave-Solder — Troubleshooting Guide (Faultiest Station on Line-E)"
doc_type: "Troubleshooting Guide"
line_id: "Line-E"
station_position: 6
station_type: "Wave-Solder"
version: "1.0"
owner: "Maintenance Engineering"
last_reviewed: "2026-01-15"
---

# Wave-Solder — Troubleshooting Guide

> **Audience:** Maintenance Tech (primary) · Line Manager · Quality Worker
> **Applies to:** Line-E, station 6, Wave-Solder

## 1. Purpose

Wave-Solder bonds the through-hole leads inserted at station 5. With a
0.7 % per-cycle fault probability — the **highest on Line-E** — it is the
single most common cause of downtime on the electronics line. This
troubleshooting guide is the fast path from a `Fault` telemetry event back
to `Running` for the three tracked fault types.

## 2. Normal operating envelope

- Ideal cycle time: **35 s**
- Max acceptable cycle time: **44 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.7 %** (line max)
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Through-Hole-Insert (station 5) is not feeding boards. | Verify Through-Hole-Insert state. |
| `Blocked` | Functional-Test (station 7) buffer full. | Verify Functional-Test state. |

Because of this station's high fault rate, **most downstream `Starved`
events on Line-E trace back to this station**. When triaging starvation on
stations 7 or 8, check Wave-Solder first.

## 4. Faults & corrective actions

### 4.1 `Solder-Temp-Drift`

- **Symptoms in telemetry:** `fault_type = "Solder-Temp-Drift"`. Joint
  quality rejects rise at Functional-Test; cold-joint codes cluster.
- **Likely root cause:** thermocouple drift, heater control failing.
- **Corrective action:**
  1. Verify pot temperature against a calibrated probe.
  2. If drift > 5 °C, calibrate or replace the thermocouple.
  3. Inspect heater elements; replace if degraded.
- **Restart criteria:** pot temperature stable within ± 3 °C of setpoint
  for 10 minutes.

### 4.2 `Flux-Low`

- **Symptoms in telemetry:** `fault_type = "Flux-Low"`. Wetting defects
  rise; some leads show open joints.
- **Likely root cause:** flux reservoir near-empty; spray nozzles clogged.
- **Corrective action:**
  1. Refill flux reservoir.
  2. Inspect and clean spray nozzles.
  3. Verify flux coverage on a test board.
- **Restart criteria:** uniform flux coverage observed on the test board.

### 4.3 `Conveyor-Speed-Fault`

- **Symptoms in telemetry:** `fault_type = "Conveyor-Speed-Fault"`. Time
  in the wave is wrong; large solder defect spike.
- **Likely root cause:** drive motor encoder failure, or VFD tripped.
- **Corrective action:**
  1. LOTO. Inspect encoder cable and connection.
  2. Verify VFD fault code; reset or replace.
- **Restart criteria:** conveyor speed stable across 5 minutes.

## 5. Preventive maintenance schedule

- **Daily:** dross removal; flux check; profile log.
- **Weekly:** clean spray nozzles; inspect fingers.
- **Monthly:** solder analysis for contamination.
- **Quarterly:** full conveyor service.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `OEE_Targets_and_Escalation.pdf`
- `Line-E_05_Through-Hole-Insert_SOP.pdf`
- `Line-E_07_Functional-Test_SOP.pdf`
