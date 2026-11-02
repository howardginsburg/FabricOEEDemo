# Fabric IQ design

How the demo's Fabric IQ layer is put together, and why. The ontology itself is mapped in
[ontology/README.md](../ontology/README.md); the agents are in [agent/README.md](../agent/README.md).

```
Simulator ─► Eventstream ─► Eventhouse ManufacturingEH ──── OneLake mirror ──► ManufacturingLH (dbo shortcuts)
             (custom         Bronze *_Raw → Silver                               │            │
              endpoint)      + derived WorkOrders, Parts, PartPasses             │            │
                             + OeeFacts()/OeeKpis()                              ▼            ▼
                                   │                                    OEEFactoryOntology   OEEAnalytics
                                   │                                    (TMDL, Sql.Database  (Direct Lake on
                                   │                                     + ONT_* → graph)     OneLake, DAX)
                                   ▼                                            │              │
                    OEE Data Agent: ontology → OEEAnalytics → ManufacturingEH ◄─┴──────────────┘
                                   │
     Foundry agent oee-factory-iq: Foundry IQ knowledge base (SOP index + ontology) + data agent
     Operations agent: ontology rules, checked by Rule*() functions in ManufacturingEH → Teams
     Evaluations: scripts/12-evaluate-agent.py
```

## 1. One business model, many consumers

The ontology is where the plant's meaning lives: what a station, a work order, or a part pass
is, how they relate, what each business rule requires, and how each KPI is defined. The Data
Agent, the Foundry IQ knowledge base, the operations agent, and the graph all read it, so a rule
or definition changes in one place. The TMDL in `ontology/OEEFactoryOntology.Ontology/` is the
source of truth and is published by `scripts/6-publish-ontology.py`; nothing is edited in the
portal except graph materialization.

## 2. The ontology binds the lakehouse; the semantic model sits beside it

The new ontology experience can bind to a semantic model, and the demo has a governed one
(`OEEAnalytics`). They stay **adjacent, not bound**:

- Data agents and operations agents can't use semantic-model-bound ontologies.
- The graph needs physical, keyed backing tables, and the rules and metrics need SQL over them.

So the ontology binds `ManufacturingLH` through its SQL analytics endpoint (a `Sql.Database`
expression with the eight `ONT_*` partition annotations, which make it graph-eligible), and the
Data Agent uses `OEEAnalytics` as a separate source for governed KPI slices. Each ontology
metric has a DAX twin, and `--check-metrics` reports any drift between them.

## 3. Events are entities, telemetry is time series

The old slim ontology kept every event out of the model. Now:

- **Keyed derived tables** make events addressable: `WorkOrders` (one row per work order),
  `Parts` (one per part), and `PartPasses` (one per part per station) are cascaded from the Silver
  tables by filter-and-project update policies (no lookups, so streaming ingestion stays on).
- **Keyless events** are entities too: `PartPass` and `MaintenanceEvent` carry the station-pass
  and work-order-lifecycle history, which gives part genealogy and work-order timelines in the
  graph.
- **Telemetry** is a set of time-series properties on `Machine` (status, idle reason, the station
  that caused an idle, flags, cycle time, buffers). The latest value per machine is its current
  state. `root_cause_device_id` makes rule `StarvedBlockedRootCause` answerable from the ontology
  itself: starved or blocked time counts against the station that caused it, not the idle one.

Time series bind through the lakehouse, so the ontology trails the Eventhouse by the OneLake
mirror's latency (about 5 minutes). Questions about a specific window or the last few minutes go
to the Eventhouse through the Data Agent.

## 4. One definition per KPI

| Layer | Where |
|---|---|
| Eventhouse | `OeeFacts(start, end, bucket)` returns additive counts; `OeeKpis()` turns sums into ratios at any grain |
| Semantic model | `_Measures.tmdl` in `OEEAnalytics` |
| Ontology | `metrics/*.tmdl` (SQL over the backing tables) |

Availability is measured as running samples over all samples, so idle (starved or blocked) time
counts against it. The OEE targets policy defines Availability without idle time; the ontology rule
`AvailabilityDefinition` records that the reports and agents use the measured definition.
Schedule adherence compares parts that left the line with the plan pro-rated to the minutes the
line ran.

The Data Agent's KQL generator validates queries against tables only and can't see stored
functions, so `scripts/7-setup-data-agent.py` inlines `OeeFacts`/`OeeKpis` as `let` statements in
its example queries.

## 5. Rules come from the SOPs

The ontology's 13 rules restate the escalation, quarantine, maintenance, safety, and attribution
policies from the SOP corpus, tied to the properties they reference (for example,
`RejectRateQuarantine` references each station's `target_reject_rate`). The ontology connector in
the Data Agent exposes entity data but not rules, so script 7 renders the rules into the agent's
instructions at publish time. The operations agent applies the same rules (section 9).

## 6. The Data Agent routes ontology first

`OEE Data Agent` has three sources, in this order of preference: the ontology (what, which, who,
relationships, current state, rules), `OEEAnalytics` (governed KPIs over the full history), and
`ManufacturingEH` (windows, trends, timelines, rule checks over a rolling window). Script 7 builds
and publishes it without a portal step; new-experience ontologies attach through an
`ontologies/<name>/ontology.json` part rather than a data source file.

The agent's orchestrator rewrites each question for the source it picks. Whether a duration rule
fired ("OEE below 60% for more than 15 minutes") can't be read from a KPI over the full history,
and when the orchestrator prescribed its own method, the generated run detection named the wrong
lines. So the instructions send every duration or rolling-window rule check to `ManufacturingEH`
in the user's words, and its example query measures how long each line or station has been below
60%: from the 5-minute bucket after its last one at or above 60%.

## 7. The Foundry agent: a knowledge base plus the data agent

`oee-factory-iq` has two tools in its default (`knowledge-base`) mode:

- **`oee-knowledge`**: a Foundry IQ knowledge base in Azure AI Search with two knowledge
  sources, the `oee-sops` index and the ontology. It plans subqueries across both and returns a
  cited answer.
- **`oee-data-agent`**: the Data Agent through the Fabric IQ tool, for numbers.

Both act on behalf of the signed-in user. Agent Service passes the user's token to the
knowledge base's ontology source, so answers respect Fabric permissions. The ontology source
answers with a live query over the ontology's data, which can run up to its own 100-second
timeout. The knowledge base therefore stores a 150-second retrieve budget (the service default
of 90 seconds failed whole responses), and its retrieval instructions keep procedure, condition,
and KPI questions on the SOP source. The agent sends the knowledge base only the knowledge part
of a question, never a KPI computation. `--knowledge tools` switches to separate tools (AI
Search, the ontology's Fabric IQ tool, and the data agent).

## 8. Evaluate, change, re-evaluate

`scripts/12-evaluate-agent.py` runs the persona question set in `agent/evals/cases.json`
through the agent and adds a run to a Foundry evaluation. Deterministic checks (routing to the
right knowledge, required facts) sit next to Foundry's AI judges. Facts that exist only in
reference data are read from the Eventhouse at run time, so the question set never copies seed
values. See [agent/evals/README.md](../agent/evals/README.md) for the baseline and how the
first round of findings changed the agents.

## 9. The operations agent: ontology rules over the Eventhouse

`OEE Operations Agent` (preview) watches the plant about every five minutes and messages the
recipient in Teams when an alert rule fires. Its rules are the ontology's: script 11 reads the
rule statements from the deployed ontology and renders them into the agent's instructions. Its
knowledge source is `ManufacturingEH`, not the ontology:

- An ontology source can evaluate only a property's latest value: no aggregations, and its time
  series must be bound to an Eventhouse. Every alert rule here counts events or computes a rate or
  an OEE over a time window.
- Operations agents don't support semantic-model-bound ontologies either.

Each alert rule is checked by a stored function in `ManufacturingEH`, `Rule<RuleName>()`, created
by script 1 next to `OeeFacts`/`OeeKpis`. It returns one row per station or line where the rule
fires, with every value the message needs (the rule name, the line and station, the evidence,
the threshold, and the window), and counts a station or line only while it's reporting, so stale
data never alerts. The rule's statement stays in the ontology; the function is its executable
form, the way each ontology metric has a SQL and a DAX form.

The playbook (the rules the agent evaluates) is generated from the instructions through the
agent's remote MCP endpoint, so no portal step is needed. The functions are what made generation
reliable. Asked to derive windowed counts, rates, and OEE from the tables, the generator built
its own intermediate queries, dropped joins, and failed different rules on each attempt, even
when the instructions spelled out the logic. Pointed at one function per rule, it bound all six
rules on the first attempt, `LineOeeEscalation` included. The shift handover report isn't a
condition to monitor. The agent is left stopped so it doesn't use capacity; `--start` and
`--stop` call the MCP endpoint's `start_agent` and `stop_agent`.

## Not included

- **Eventhouse-native time-series bindings**: available in the portal, but their TMDL shape
  isn't documented, so the publisher can't produce them yet.
- **A schema-aware Eventstream**: the event contracts are published as an Event Schema Set
  (`scripts/1a-publish-event-schemas.py`), but associating them with a stream needs a new
  Eventstream created in the portal.
