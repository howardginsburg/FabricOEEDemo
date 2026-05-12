---
title: "Quality — Reject Disposition Policy"
doc_type: "Policy"
version: "1.0"
owner: "Quality Engineering"
last_reviewed: "2026-01-15"
---

# Quality — Reject Disposition Policy

> **Audience:** Quality Worker · Line Manager · Plant Manager
> **Applies to:** Every part flagged `rejected` in the simulator's part
> event stream, on any of the 30 stations.

## 1. Purpose

This policy defines what happens to a part once it is flagged as a reject
by any station's inspection or test. The decision tree is the same across
all 5 lines but the **threshold values and dispositions differ by line and
by station**.

## 2. Reject thresholds by station

Reject probability targets from the simulator and the operational limits
above which the line should pause for triage:

| Line | Station | Target reject rate | Pause threshold (1 hr rolling) |
|---|---|---|---|
| Line-A | CNC-Lathe | 2 % | > 4 % |
| Line-A | CNC-Mill | 3 % | > 5 % |
| Line-A | Surface-Grinder | 2 % | > 4 % |
| Line-A | Deburring-Station | 1 % | > 3 % |
| Line-A | CMM-Inspection | 5 % | > 8 % |
| Line-B | Blanking-Press | 2 % | > 4 % |
| Line-B | Hydraulic-Press | 4 % | > 6 % |
| Line-B | Trimming-Station | 2 % | > 4 % |
| Line-B | Quality-Inspection | 3 % | > 5 % |
| Line-C | Welding-Robot | 3 % | > 5 % |
| Line-C | Weld-Inspection | 4 % | > 7 % |
| Line-C | Fastening-Station | 1 % | > 3 % |
| Line-C | Assembly-Robot | 2 % | > 4 % |
| Line-C | Leak-Test | 3 % | > 5 % |
| Line-D | Surface-Prep | 1 % | > 3 % |
| Line-D | Chemical-Wash | 1 % | > 3 % |
| Line-D | Primer-Application | 3 % | > 5 % |
| Line-D | Paint-Booth | 4 % | > 6 % |
| Line-D | Curing-Oven | 2 % | > 4 % |
| Line-D | Coating-Inspection | 3 % | > 5 % |
| Line-E | SMT-Placement | 3 % | > 5 % |
| Line-E | Reflow-Oven | 2 % | > 4 % |
| Line-E | AOI-Inspection | 4 % | > 7 % |
| Line-E | Through-Hole-Insert | 2 % | > 4 % |
| Line-E | Wave-Solder | 3 % | > 5 % |
| Line-E | Functional-Test | 5 % | > 8 % |
| Line-E | Conformal-Coat | 2 % | > 4 % |

When a line crosses any pause threshold, the **Line Manager pauses the
station for triage**, and the relevant station SOP is consulted to identify
the likely fault even if `machine_status` is still `Running`.

## 3. Disposition decision tree

For every rejected part:

1. **Capture context** — part ID, line, station, reject reason code,
   `fault_type` of any open work order on that station.
2. **Classify the defect**:
   - **Cosmetic** (surface finish, edge break, minor visual) → see step 4.
   - **Dimensional / functional** (outside tolerance, leak, electrical) →
     see step 5.
   - **Safety-critical** (e.g., weld penetration failure, leak on a
     pressure boundary) → see step 6.
3. **Apply line-specific routing** below.

### 4. Cosmetic defect

- **Rework** at the originating station if rework is technically feasible
  (e.g., Deburring re-passes, Coating-Inspection paint touch-up).
- If rework is not feasible, route to **scrap** with disposition code
  `COS-SCRAP`.

### 5. Dimensional / functional defect

- **Quarantine** the part until a Quality Engineer reviews.
- For Line-A CMM-Inspection rejects → check the prior 5 parts on CMM
  (sampling).
- For Line-C Weld-Inspection or Leak-Test rejects → hold the **entire
  buffer of parts produced after the last good cycle**.
- For Line-E AOI-Inspection or Functional-Test rejects → hold the
  individual board; route to engineering rework if cost-justified, else
  scrap with code `FUNC-SCRAP`.

### 6. Safety-critical defect

- **Immediate quarantine** of the part with red tag.
- Notify Line Manager and Quality Engineer.
- Trigger a **3-piece holdback rule** on the affected station: hold the
  prior 3 parts in addition to the rejected one until QE has reviewed.
- Create a maintenance work order against the station even if
  `machine_status` is still `Running` — this often indicates a brewing
  fault not yet escalated by telemetry.

## 7. RMA & customer returns

Returned product from the field is processed by Quality Engineering and not
covered by line dispositions. RMA disposition codes (`RMA-INVESTIGATE`,
`RMA-CREDIT`, `RMA-REPAIR-RETURN`) are tracked separately.

## 8. References

- Each station SOP §3 ("Idle reasons") and §4 ("Faults & corrective
  actions").
- `Maintenance_Workflow_Overview.pdf` for the work-order lifecycle.
- `OEE_Targets_and_Escalation.pdf` for the Quality component of OEE.
- `Production_Lines_Reference.pdf` for line topology.
