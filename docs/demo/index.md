# Run the demo

The demo tells one story: a factory floor streams its telemetry into Fabric, things go wrong on cue, and every
layer reacts, from the live dashboard and the report to the alerts and the agents. These pages walk through it
in presenting order, with what to show and what to say at each step.

| Page | Shows | Needs setup steps |
|---|---|---|
| [The factory floor](factory-floor.md) | The simulator and its demo scenarios | 1, 2 |
| [Real-time operations](real-time.md) | The Eventstream, the Eventhouse, the Real-Time Dashboard, and the outage email | 1, 2, 6 |
| [Analytics and write-back](analytics.md) | The Direct Lake report, and setting an OEE target from it | 3, 5 |
| [Floor Ops Console](floor-ops.md) | Operators logging issues that join the machine data | 4, 5 |
| [Ontology and graph](ontology.md) | The plant's business model and its graph | 7 |
| [OEE Data Agent](data-agent.md) | Questions answered with the ontology as context, in KQL, SQL, or DAX | 7 |
| [Foundry agent](foundry-agent.md) | The OEE Factory IQ agent, its knowledge base over the SOPs and the ontology, procedures and data in one answer, and the evaluations | 9, 10 |
| [Operations agent](operations-agent.md) | Alerts when the plant breaks its own rules | 8 |

## Before you present

- [ ] **Resume the capacity** if it's paused, then check that the Eventstream's destinations are
      **Running** ([setup step 1](../setup/fabric-foundation.md#check-the-eventstream)).
- [ ] **Start the simulator at least 30 minutes ahead**, and an hour if you can. The floor needs a few minutes
      to fill its buffers, and the "latest hour" views, the report, and the agents need data to work with.
- [ ] **Start the operations agent** (`scripts/11-setup-operations-agent.py --start`). It first reports what's
      already true, typically a line or two that has run below 60% OEE, so start it before you present.
- [ ] **Sign in to Outlook** on the presenting machine to show the outage email as it arrives, and to Microsoft
      Teams if your tenant has it, for the operations agent's messages.
- [ ] **Open the tabs** in presenting order: the simulator, the `manufacturing-telemetry` Eventstream, the
      `ManufacturingEH` KQL database, the Real-Time Dashboard, the `OEEAnalytics` report, the Floor Ops Console,
      `OEEFactoryOntology`, the OEE Data Agent, and in the Foundry portal, the `oee-factory-iq` agent and the
      `oee-factory-kb` knowledge base.
- [ ] **Ask each agent one question** beforehand. The first answer of a session is the slowest.
- [ ] **Wake the lakehouse's SQL analytics endpoint** a few minutes before you show the ontology and the agents:
      open `ManufacturingLH`, switch to its **SQL analytics endpoint**, and select **Refresh**. The endpoint stops
      syncing after 15 minutes without queries, and the ontology reads the plant's records through it, so until
      something wakes it those records can be hours old. Telemetry and work order steps come straight from the
      Eventhouse either way.

## Run of show

The alerts take a few minutes to arrive, so fire the scenarios at the start and come back to the alerts at the end.
All four scenarios are buttons in the simulator's **Demo Scenarios** panel; see
[The factory floor](factory-floor.md#demo-scenarios).

| Step | Do this | You'll see |
|---|---|---|
| 1 | Show the floor, then fire **Slow cycles** on the Line-A CMM-Inspection | Line-A's Performance drops at once. The operations agent's station escalation follows in about 20 minutes. |
| 2 | Fire **Long outage** on the Line-D Curing-Oven | An outage email within a few minutes. Line-D's downstream stations starve and its upstream stations block. The bottleneck alert arrives about 10 minutes after you fire it. |
| 3 | Fire **Reject spike** on the Line-B Quality-Inspection | Line-B's Quality drops. The quarantine alert arrives once the station has rejected 3 parts in the hour. |
| 4 | [Real-time operations](real-time.md) | The events land, and the dashboard and the email show the outage |
| 5 | [Analytics and write-back](analytics.md) | The report, and a new OEE target for Line-D |
| 6 | [Floor Ops Console](floor-ops.md) | An operator raises the Curing-Oven issue; a supervisor works it |
| 7 | Fire **Repeat faults** on the Line-B Hydraulic-Press | Three outage emails, then the preventive maintenance alert a few minutes after the third fault |
| 8 | [Ontology and graph](ontology.md) | What a station, a rule, and a metric mean, and how they connect |
| 9 | [OEE Data Agent](data-agent.md) | Which station caused Line-D's starved and blocked time |
| 10 | [Foundry agent](foundry-agent.md): tour the agent and its knowledge base, then fire **Fault now** on the Line-D Curing-Oven and ask about it | The knowledge base's two sources, the documents and the ontology, and the Curing-Oven's Thermocouple-Drift procedure with its open work order |
| 11 | [Operations agent](operations-agent.md) | The alerts from steps 1, 2, 3, and 7 in its activity log |

When you're done, [clean up](../setup/clean-up.md): stop the operations agent and the simulator, and pause the
capacity.
