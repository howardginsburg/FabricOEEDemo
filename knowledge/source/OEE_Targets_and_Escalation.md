---
title: "OEE Targets and Escalation Matrix"
doc_type: "Policy"
version: "1.0"
owner: "Operations / Plant Management"
last_reviewed: "2026-01-15"
---

# OEE Targets and Escalation Matrix

> **Audience:** Plant Manager · Line Manager · Corp Exec · Maintenance Lead
> **Applies to:** All 5 production lines.

## 1. Purpose

This document is the corporate KPI definition for **Overall Equipment
Effectiveness (OEE)** at this site, the **target values** each line is held
to, and the **escalation matrix** that fires when targets are missed.

## 2. OEE definition (matches the Fabric Dashboard)

```
OEE = Availability × Performance × Quality
```

- **Availability** = `Running` time ÷ (`Running` + `Fault` + `Maintenance`)
  time. `Idle` time (`Starved` or `Blocked`) is **excluded** because it
  reflects neighboring-station issues, not the station's own availability.
- **Performance** = ideal cycle time ÷ actual cycle time.
- **Quality** = (parts produced − rejected parts) ÷ parts produced.

The Fabric Eventhouse `OEE_5min` materialized view computes these
components on rolling 5-minute windows by station and line. The Real-Time
Dashboard surfaces them on the Plant Manager and Line Manager pages.

## 3. Site-level targets

| Tier | Target OEE | Comment |
|---|---|---|
| World-class | ≥ 85 % | Aspirational; achievable only on Line-B with bottleneck balanced. |
| **This site's commitment** | **≥ 75 %** | Quarterly review with Corp Exec. |
| Acceptable | 60 – 75 % | Normal operating band. |
| Action required | < 60 % | Escalation triggers fire — see §5. |

## 4. Line-level targets

| Line | Bottleneck | Target OEE | Notes |
|---|---|---|---|
| Line-A | CMM-Inspection (60 s) | 78 % | Quality target capped by CMM reject rate (≤ 5 %). |
| Line-B | Hydraulic-Press fault rate | 72 % | Availability target capped by 1.5 % fault rate. |
| Line-C | Welding-Robot + Leak-Test | 75 % | Watch reject rate from Weld-Inspection. |
| Line-D | Curing-Oven (90 s) | 70 % | Slowest line; Performance capped by oven cycle. |
| Line-E | Wave-Solder fault rate | 73 % | Highest fault-rate line; quality from Functional-Test. |

## 5. Escalation matrix

| Condition | Sustained for | Notify | Action |
|---|---|---|---|
| Station OEE < 60 % | > 15 min | Line Manager | Pause for triage; check station SOP §4. |
| Line OEE < 60 % | > 15 min | Plant Manager | Open incident review; suspend non-urgent changes. |
| Line OEE < 60 % | > 1 hr | Corp Exec | Daily-flash report. |
| ≥ 3 faults on the same station | within 1 hr | Maintenance Lead | Pull station for PM regardless of schedule; root-cause review. |
| Reject rate > 2× target | within 1 hr | Quality Engineer | Quarantine all buffer parts on that station per `Quality_Reject_Disposition_Policy.pdf`. |
| Two concurrent open work orders on the same line | any time | Line Manager + Maintenance Lead | Re-balance technicians; check `Maintenance_Workflow_Overview.pdf` §4. |
| Bottleneck station downtime (CMM, Curing-Oven, Wave-Solder) | > 5 min | Line Manager | Notify Plant Manager; check related SOP. |

## 6. Bottlenecks and OEE sensitivity

A 5-minute outage on a bottleneck station translates almost directly to
5 minutes of lost line throughput. Watch carefully:

- **Line-A CMM-Inspection** — see `Line-A_05_CMM-Inspection_Calibration.pdf`.
- **Line-D Curing-Oven** — see `Line-D_05_Curing-Oven_SOP.pdf`.
- **Line-E Wave-Solder** — see `Line-E_06_Wave-Solder_Troubleshooting.pdf`.

Non-bottleneck stations can absorb short outages within buffer capacity
(5 parts each), but cascading starvation through the line still erodes OEE
within ~1–2 cycle times of the slowest station.

## 7. References

- `Maintenance_Workflow_Overview.pdf` — fault → WO → resolution.
- `Quality_Reject_Disposition_Policy.pdf` — Quality component handling.
- `Safety_Lockout_Tagout_Procedure.pdf` — all maintenance work requires LOTO.
- `Production_Lines_Reference.pdf` — line topology.
- `Shift_Handover_Checklist.pdf` — OEE component is reported on handover.
