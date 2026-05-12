---
title: "Through-Hole-Insert — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-E"
station_position: 5
station_type: "Through-Hole-Insert"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Through-Hole-Insert — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-E, station 5, Through-Hole-Insert

## 1. Purpose

Through-Hole-Insert installs through-hole connectors and taller components
(connectors, electrolytic capacitors) that cannot survive reflow. These
parts will be wave-soldered at station 6.

## 2. Normal operating envelope

- Ideal cycle time: **20 s**
- Max acceptable cycle time: **26 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.5 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | AOI-Inspection (station 4) is not feeding boards. | Verify AOI-Inspection state. |
| `Blocked` | Wave-Solder (station 6) buffer full. | Verify Wave-Solder state. |

## 4. Faults & corrective actions

### 4.1 `Lead-Bend`

- **Symptoms in telemetry:** `fault_type = "Lead-Bend"`. Insertion fails;
  alarm raised on the affected channel.
- **Likely root cause:** lead-forming tooling worn; component lot
  out of spec.
- **Corrective action:**
  1. LOTO. Replace forming dies.
  2. Verify component lead spacing matches the recipe.
- **Restart criteria:** five clean insertions on the offending channel.

### 4.2 `Insertion-Miss`

- **Symptoms in telemetry:** `fault_type = "Insertion-Miss"`. Component
  not detected after insert; downstream Functional-Test will reject.
- **Likely root cause:** insertion head off-position or magazine empty.
- **Corrective action:**
  1. Re-teach insertion head position.
  2. Reload magazine.
- **Restart criteria:** detection on 10 consecutive cycles.

### 4.3 `Clinch-Fail`

- **Symptoms in telemetry:** `fault_type = "Clinch-Fail"`. Component
  inserted but not retained.
- **Likely root cause:** clinch tooling worn; clinch pressure low.
- **Corrective action:**
  1. LOTO. Inspect clinch die; replace if worn.
  2. Verify clinch pressure.
- **Restart criteria:** clinch test pulls within spec.

## 5. Preventive maintenance schedule

- **Daily:** verify magazines; check tooling.
- **Weekly:** inspect insertion head; clean.
- **Monthly:** clinch die service.
- **Quarterly:** head accuracy verification.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Line-E_04_AOI-Inspection_SOP.pdf`
- `Line-E_06_Wave-Solder_Troubleshooting.pdf`
