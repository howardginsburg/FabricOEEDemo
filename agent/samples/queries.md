# OEE Factory IQ — Sample Queries

Persona-tagged prompts for exercising the agent. Each prompt is annotated
with the knowledge source(s) it should hit:

- `[Fabric DA – ontology]` — answered by the Fabric Data Agent's **ontology**
  source (simple `Avg`/`Sum`/`Count` of a TS proxy column, grouped by
  `ProductionLine` / `Station` / `ProductionSchedule`, or a static lookup /
  category rollup via `Shift` / `MachineType` / `IssueType` / `Technician` /
  `SOP` / `Policy`).
- `[Fabric DA – KQL DB]` — answered by the Fabric Data Agent's **KQL Database**
  source (NL2KQL against `ManufacturingEH`; needed for single-record lookups,
  joins, `countif`, windowing, Performance/OEE composition, trend over time).
- `[AI Search]` — answered from the SOP PDF corpus.
- `[both]` — answer combines live state with procedure.

The set covers all 5 lines and at least one of every cross-cutting doc.

---

## Corp Exec

1. `[Fabric DA – KQL DB]` "What's the site-wide OEE right now and how does it
   compare to our 75 % commitment?"
   *(Needs Performance composition → KQL DB via `MachineEventsEnriched()`.)*

2. `[AI Search]` "What's the escalation policy when a line drops below
   60 % OEE?" *(expect `OEE_Targets_and_Escalation.pdf`)*

3. `[both]` "Which lines are currently below their target OEE, and what
   actions does our policy require?"
   *(OEE per line via KQL DB; policy via AI Search.)*

---

## Plant Manager

4. `[Fabric DA – KQL DB]` "Show me OEE for all 5 lines over the past hour and
   flag any line under 60 %."
   *(Trend + composition → KQL DB.)*

5. `[AI Search]` "What are the bottleneck stations on each line and why
   are they the bottleneck?" *(expect `Production_Lines_Reference.pdf`)*

6. `[both]` "Line-D OEE just dropped — what's the most likely bottleneck
   today and what's the current state of the Curing-Oven?"
   *(Station state via ontology TS slice; OEE drop + Curing-Oven detail
   via KQL DB; bottleneck reference via AI Search.)*

---

## Line Manager

7. `[Fabric DA – ontology]` "On Line-B, list any stations currently in Fault
   or Maintenance state."
   *(`Avg(is_fault)` and `Avg(is_maintenance)` on `Station` TS, filtered to
   `line_id == "Line-B"`, last 30 s. For the technician name on each open
   WO, follow up with KQL DB.)*

8. `[AI Search]` "What's the pause threshold for the Welding-Robot on
   Line-C and what should I do when I cross it?" *(expect
   `Line-C_02_Welding-Robot_SOP.pdf` and
   `Quality_Reject_Disposition_Policy.pdf`)*

9. `[both]` "The Line-E AOI-Inspection reject rate has been creeping up
   — show me the trend and tell me what to do next."
   *(Trend → KQL DB binned `summarize`; procedure → AI Search.)*

---

## Maintenance Tech

10. `[both]` "Line-D Curing-Oven just raised a `Thermocouple-Drift`
    fault — what's the corrective procedure and is there an open work
    order?" *(WO lookup → KQL DB `arg_max` on `MaintenanceEvents`;
    procedure → AI Search → `Line-D_05_Curing-Oven_SOP.pdf`.)*

11. `[AI Search]` "Walk me through the LOTO procedure for the Line-B
    Hydraulic-Press." *(expect `Safety_Lockout_Tagout_Procedure.pdf` +
    `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf`)*

12. `[Fabric DA – KQL DB]` "What faults has Line-A CNC-Lathe had in the last
    24 h, and who acknowledged each work order?"
    *(`MachineEvents | where machine_status == "Fault"` + join to
    `MaintenanceEvents` for technician_id — both KQL DB.)*

---

## Quality Worker

13. `[AI Search]` "If Line-A CMM-Inspection rejects exceed 8 % in an
    hour, what do I do?" *(expect
    `Quality_Reject_Disposition_Policy.pdf` + CMM SOP)*

14. `[both]` "I have a part that failed Line-C Leak-Test — what's the
    disposition decision tree, and how many parts are sitting in the
    Leak-Test buffer right now?"
    *(Buffer count via ontology `Station` TS — `Max(input_buffer_count)`
    on the Leak-Test station; disposition tree → AI Search.)*

15. `[AI Search]` "What does the shift-handover checklist say about
    open quality holds?" *(expect `Shift_Handover_Checklist.pdf`)*

---

## Reliability / Continuous-Improvement (reference dimensions)

16. `[Fabric DA – ontology]` "Group the 30 machine types by category and
    tell me how many stations are in each."
    *(`MachineType.category` rollup via `Station_Is_Of_MachineType`.)*

17. `[Fabric DA – KQL DB]` "Which fault category has caused the most
    maintenance events in the last 7 days?"
    *(`MaintenanceEvents` ⋈ `IssueTypeMaster` on `issue_type`, group by
    `category` — KQL DB join.)*

18. `[Fabric DA – KQL DB]` "How many work orders did each technician close
    this week, by name?"
    *(`MaintenanceEvents` ⋈ `TechnicianMaster` on `technician_id` — KQL DB.)*

19. `[both]` "Which process family (machining, forming, joining, surface,
    electronics, inspection) has the lowest availability right now, and what's
    the SOP for its worst station?"
    *(Availability by `MachineType.category` via KQL DB join to
    `MachineTypeMaster`; SOP via `SOP_AppliesTo_Station` → `file_name` → AI Search.)*

20. `[Fabric DA – ontology]` "List the planned parts for each line on the
    Night shift."
    *(`ProductionSchedule` ⋈ `Shift` via `ProductionSchedule_For_Shift`,
    filter `shift == "Night"`.)*
