# Sample questions

<!-- Generated from agent/evals/cases.json by `python scripts/12-evaluate-agent.py --write-samples`.
     Edit the cases file, then regenerate this page. -->

Questions from the demo's six personas for the [OEE Factory IQ agent](foundry-agent.md). They're also
the question set that `scripts/12-evaluate-agent.py` evaluates the agent on. Each question names the
knowledge its answer needs:

- **SOPs**: the SOP and policy documents, through the Foundry IQ knowledge base (or the AI Search
  tool in tools mode).
- **Ontology**: the Fabric IQ ontology's entities, relationships, current machine state, and
  business rules.
- **Data agent**: the OEE Data Agent's governed KPIs from the Direct Lake semantic model and its
  event detail from the Eventhouse.

Questions that need only the data agent or the ontology also work in the
[OEE Data Agent](data-agent.md) itself.

## Corp Exec

1. "What's the site-wide OEE, and how does it compare to our 75% commitment?"
   *Data agent*: Governed OEE measure from the Direct Lake semantic model, through the data agent.

2. "What's our escalation policy when a line's OEE drops below 60%?"
   *SOPs or Ontology*: Escalation matrix from the OEE targets policy and the ontology rule LineOeeEscalation.

3. "Which lines are below their OEE target, and what does our escalation policy require for them?"
   *Data agent + (SOPs or Ontology)*: OEE against each line's write-back target (OeeTarget) from the data agent, plus the escalation rule.

## Plant Manager

4. "Show me OEE for all five lines over the latest hour of data, and flag any line under 60%."
   *Data agent*: KPIs for a time window from the Eventhouse (the OeeFacts and OeeKpis definitions), through the data agent.

5. "What are the bottleneck stations on each line, and why are they the bottleneck?"
   *SOPs*: Line topology and bottlenecks from the production lines reference.

6. "Line-D's OEE dropped. What's its bottleneck, and what's the current state of the Curing-Oven?"
   *Ontology or Data agent*: Current machine state from the ontology (Machine time series) with the line topology.

7. "How is each line tracking against its production plan, by Day and Night shift?"
   *Data agent*: Governed Schedule Adherence measure from the Direct Lake semantic model, by line and shift.

8. "List the planned parts for each line on the Night shift."
   *Ontology or Data agent*: The ProductionSchedule entity and its Shift relationship in the ontology.

## Line Manager

9. "On Line-B, list any stations currently in Fault or Maintenance."
   *Ontology or Data agent*: Current machine state from the ontology's Machine time series.

10. "What's the pause threshold for the Welding-Robot on Line-C, and what should I do when it's crossed?"
   *SOPs*: Reject thresholds from the quality policy, with the station SOP.

11. "The Line-E AOI-Inspection reject rate has been creeping up. Show me the trend and tell me what to do next."
   *Data agent + SOPs*: A reject-rate trend from the Eventhouse, plus the station SOP and the quality policy.

12. "Which station caused the most starved or blocked time on Line-D, and why?"
   *Data agent*: Starved and blocked root-cause attribution (rule StarvedBlockedRootCause) from the Eventhouse.

## Maintenance Tech

13. "The Line-D Curing-Oven just raised a Thermocouple-Drift fault. What's the corrective procedure, and is there an open work order?"
   *SOPs + Data agent*: SOP corrective action, plus open work orders from the data agent.

14. "Walk me through the LOTO procedure for the Line-B Hydraulic-Press."
   *SOPs*: The safety procedure plus the station's notes, from two documents.

15. "What were the five most recent faults on the Line-A CNC-Lathe, and who acknowledged each work order?"
   *Data agent*: Work-order timelines (the MaintenanceEvent lifecycle) through the data agent.

## Quality Worker

16. "If Line-A CMM-Inspection rejects exceed 8% in an hour, what do I do?"
   *SOPs*: Quality policy thresholds and dispositions, with the CMM calibration procedure.

17. "I have a part that failed the Line-C Leak-Test. What's the disposition decision tree, and how many parts are in the Leak-Test input buffer right now?"
   *SOPs + (Ontology or Data agent)*: The quality policy's decision tree, plus current buffer state from the ontology.

18. "What does the shift-handover checklist say about open quality holds?"
   *SOPs*: Checklist retrieval from a cross-cutting document.

19. "What does our business rule say when a station's reject rate climbs above twice its target, and what's the target reject rate for the Line-D Curing-Oven?"
   *Ontology*: The ontology rule RejectRateQuarantine with the Station target_reject_rate property.

20. "Take the most recently rejected part on Line-C and trace every station it passed through, with the outcome at each."
   *Ontology or Data agent*: Part genealogy across the ontology's Part, PartPass, and Station.

## Reliability Engineer

21. "Group the machine types by process family and tell me how many stations are in each."
   *Ontology or Data agent*: Ontology relationships (Station to MachineType) and a category rollup.

22. "Which fault category has caused the most work orders overall?"
   *Data agent*: Work orders rolled up by the IssueType category.

23. "How many work orders has each technician resolved, by name?"
   *Data agent*: Work orders joined to the Technician entity.

24. "Which process family has the lowest availability, and what's the SOP for its worst station?"
   *Data agent + (SOPs or Ontology)*: Governed Availability by machine-type category, then the SOP linked to the station.

25. "What are MTTR and MTBF by line over the full history?"
   *Data agent*: Governed MTTR (min) and MTBF (min) measures from the Direct Lake semantic model.
