# OEE Factory IQ — Sample Queries

Persona-tagged prompts for exercising the agent. Each prompt is annotated
with the knowledge source(s) it should hit:

- `[Fabric IQ]` — answered from the Fabric Data Agent (live state).
- `[AI Search]` — answered from the SOP PDF corpus.
- `[both]` — answer combines live state with procedure.

The set covers all 5 lines and at least one of every cross-cutting doc.

---

## Corp Exec

1. `[Fabric IQ]` "What's the site-wide OEE right now and how does it
   compare to our 75 % commitment?"

2. `[AI Search]` "What's the escalation policy when a line drops below
   60 % OEE?" *(expect `OEE_Targets_and_Escalation.pdf`)*

3. `[both]` "Which lines are currently below their target OEE, and what
   actions does our policy require?"

---

## Plant Manager

4. `[Fabric IQ]` "Show me OEE for all 5 lines over the past hour and
   flag any line under 60 %."

5. `[AI Search]` "What are the bottleneck stations on each line and why
   are they the bottleneck?" *(expect `Production_Lines_Reference.pdf`)*

6. `[both]` "Line-D OEE just dropped — what's the most likely bottleneck
   today and what's the current state of the Curing-Oven?"

---

## Line Manager

7. `[Fabric IQ]` "On Line-B, list any stations currently in Fault or
   Maintenance state and the assigned technician."

8. `[AI Search]` "What's the pause threshold for the Welding-Robot on
   Line-C and what should I do when I cross it?" *(expect
   `Line-C_02_Welding-Robot_SOP.pdf` and
   `Quality_Reject_Disposition_Policy.pdf`)*

9. `[both]` "The Line-E AOI-Inspection reject rate has been creeping up
   — show me the trend and tell me what to do next."

---

## Maintenance Tech

10. `[both]` "Line-D Curing-Oven just raised a `Thermocouple-Drift`
    fault — what's the corrective procedure and is there an open work
    order?" *(expect `Line-D_05_Curing-Oven_SOP.pdf` + Maintenance
    table query)*

11. `[AI Search]` "Walk me through the LOTO procedure for the Line-B
    Hydraulic-Press." *(expect `Safety_Lockout_Tagout_Procedure.pdf` +
    `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf`)*

12. `[Fabric IQ]` "What faults has Line-A CNC-Lathe had in the last
    24 h, and who acknowledged each work order?"

---

## Quality Worker

13. `[AI Search]` "If Line-A CMM-Inspection rejects exceed 8 % in an
    hour, what do I do?" *(expect
    `Quality_Reject_Disposition_Policy.pdf` + CMM SOP)*

14. `[both]` "I have a part that failed Line-C Leak-Test — what's the
    disposition decision tree, and how many parts are sitting in the
    Leak-Test buffer right now?"

15. `[AI Search]` "What does the shift-handover checklist say about
    open quality holds?" *(expect `Shift_Handover_Checklist.pdf`)*
