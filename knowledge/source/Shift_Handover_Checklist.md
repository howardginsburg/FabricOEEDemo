---
title: "Shift Handover Checklist"
doc_type: "Checklist"
version: "1.0"
owner: "Operations"
last_reviewed: "2026-01-15"
---

# Shift Handover Checklist

> **Audience:** Outgoing and incoming Operators, Line Managers, and
> Maintenance Leads.
> **Applies to:** All 5 production lines at every shift change.

## 1. Purpose

This checklist is run by the outgoing shift lead and signed by the incoming
shift lead at every shift transition. It is the canonical handover record
referenced by every per-station SOP.

## 2. Shifts on this site

The simulator runs a 3-shift, 24-hour schedule:

| Shift | Start | End | Notes |
|---|---|---|---|
| **A** | 06:00 | 14:00 | Morning shift, full staff. |
| **B** | 14:00 | 22:00 | Afternoon shift, full staff. |
| **C** | 22:00 | 06:00 | Night shift, reduced staff; maintenance window. |

Maintenance technicians T001 through T008 are scheduled across shifts so
that **at least two technicians are on duty at all times**.

## 3. Handover checklist (every transition)

### A. Production status

- [ ] Current part type running on each line.
- [ ] Open shift production target vs. actual.
- [ ] Any line currently paused for triage (see Reject Disposition Policy).

### B. Equipment status

For each line, the outgoing operator records the current `machine_status`
of each station. Anything not `Running` requires a note:

- `Idle` with `idle_reason = Starved` — name the upstream station that is
  not feeding.
- `Idle` with `idle_reason = Blocked` — name the downstream station that
  is not accepting.
- `Fault` — record `fault_type` and open work-order ID.
- `Maintenance` — record work-order ID and estimated time to restore.

### C. Open work orders

- [ ] List every open maintenance work order with: work-order ID, station,
      `fault_type`, status (Open / Acknowledged / In Progress), and
      assigned technician.
- [ ] Flag any work order older than 30 minutes for the incoming shift's
      Maintenance Lead.

### D. Quality holds

- [ ] List any parts quarantined under
      `Quality_Reject_Disposition_Policy.pdf`.
- [ ] Confirm 3-piece holdback parts have been physically segregated.
- [ ] Note any unresolved RMA investigations from the previous shift.

### E. OEE snapshot

- [ ] Capture line-level OEE for the outgoing shift from the Real-Time
      Dashboard.
- [ ] Note any line that triggered the < 60 % escalation per
      `OEE_Targets_and_Escalation.pdf`.

### F. Safety

- [ ] LOTO locks: confirm every applied lock has a matching tag with a
      named technician on the incoming shift, **or** confirm the lock will
      be removed before the previous shift leaves the floor.
- [ ] Note any near-misses or incidents to report to EHS.

### G. Bottleneck-station status

Special attention to bottleneck stations from
`Production_Lines_Reference.pdf`:

- [ ] **CMM-Inspection (Line-A)** — calibration status, last probe check.
- [ ] **Hydraulic-Press (Line-B)** — accumulator pressure, last seal check.
- [ ] **Curing-Oven (Line-D)** — temperature stability, door-seal note.
- [ ] **Wave-Solder (Line-E)** — solder-pot temperature, flux level.

### H. PM activities planned for the incoming shift

- [ ] Any preventive-maintenance task scheduled to be executed during the
      incoming shift, with station SOP reference.

## 4. Sign-off

Both shift leads sign the handover record. The record is filed by date and
shift code and is available to the Plant Manager for daily review.

## 5. References

- `Maintenance_Workflow_Overview.pdf`
- `Quality_Reject_Disposition_Policy.pdf`
- `OEE_Targets_and_Escalation.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Production_Lines_Reference.pdf`
- All 30 per-station SOPs.
