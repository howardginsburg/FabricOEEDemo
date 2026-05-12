---
title: "Functional-Test — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-E"
station_position: 7
station_type: "Functional-Test"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# Functional-Test — Standard Operating Procedure

> **Audience:** Quality Worker · Maintenance Tech · Line Manager
> **Applies to:** Line-E, station 7, Functional-Test

## 1. Purpose

Functional-Test powers up the board and runs an electrical test suite to
catch defects that visual inspection cannot. This station has the highest
reject rate on Line-E (5 %).

## 2. Normal operating envelope

- Ideal cycle time: **30 s**
- Max acceptable cycle time: **38 s**
- Expected reject rate: **≤ 5 %**
- Fault probability per cycle: **0.3 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Wave-Solder (station 6) is not feeding boards. | Verify Wave-Solder state — most common starvation cause on this line. |
| `Blocked` | Conformal-Coat (station 8) cannot accept the tested board. | Verify Conformal-Coat state. |

## 4. Faults & corrective actions

### 4.1 `Fixture-Fault`

- **Symptoms in telemetry:** `fault_type = "Fixture-Fault"`. Boards report
  no continuity on all channels — clearly a fixture problem rather than a
  board issue.
- **Likely root cause:** fixture worn, pogo pins seized, or fixture not
  fully seated.
- **Corrective action:**
  1. LOTO. Inspect pogo pins; replace worn pins.
  2. Verify fixture-to-board alignment.
- **Restart criteria:** master golden board passes 100 % of channels.

### 4.2 `Probe-Wear`

- **Symptoms in telemetry:** `fault_type = "Probe-Wear"`. False fails on
  intermittent channels.
- **Likely root cause:** probe tip worn or oxidized.
- **Corrective action:**
  1. Clean probe tips; replace fatigued probes.
- **Restart criteria:** master board passes consistently.

### 4.3 `Power-Supply-Fail`

- **Symptoms in telemetry:** `fault_type = "Power-Supply-Fail"`. Test fails
  to apply rail voltages.
- **Likely root cause:** programmable PSU faulted, fuse blown.
- **Corrective action:**
  1. LOTO. Verify PSU rails with a meter.
  2. Replace failed PSU module.
- **Restart criteria:** rails within ± 1 % of setpoint.

## 5. Preventive maintenance schedule

- **Daily:** master golden board verification.
- **Weekly:** clean probes.
- **Monthly:** PSU calibration check.
- **Quarterly:** fixture refurbishment.

## 6. References

- `Quality_Reject_Disposition_Policy.pdf`
- `Maintenance_Workflow_Overview.pdf`
- `Line-E_06_Wave-Solder_Troubleshooting.pdf`
- `Line-E_08_Conformal-Coat_SOP.pdf`
