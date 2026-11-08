---
hide:
  - navigation
---

# How it works

A simulator streams factory events into Fabric. Real-Time Intelligence lands them, OneLake makes them available
to every other engine, and Fabric IQ gives them business meaning that the reports, alerts, and agents share.

## Architecture

```mermaid
flowchart TB
    %% ---------------- Source systems ----------------
    subgraph SRC["Source systems"]
        SIM["🏭 .NET WPF Simulator<br/>5 lines · 30 stations<br/>machine · part · maintenance"]
        APP["📝 Floor Ops Console<br/>Fabric App (Rayfin, SSO)<br/>operators log FloorEvents"]
        WB["🎯 OEE-target write-back<br/>report button → Translytical UDF"]
    end

    %% ---------------- Ingest + operational stores ----------------
    subgraph STORE["Real-time ingestion & operational stores"]
        ES["⚡ Eventstream<br/>custom endpoint<br/>routes by event_type<br/>Event Schema Set contracts"]
        subgraph EH["ManufacturingEH — Eventhouse / KQL"]
            BRONZE["Bronze *_Raw"]
            SILVER["Silver enriched + derived<br/>MachineEvents · PartEvents<br/>MaintenanceEvents · WorkOrders<br/>Parts · PartPasses · dims<br/>OeeFacts() · OeeKpis()"]
            BRONZE -->|update policy| SILVER
        end
        FSQL["🗄️ Floor Ops managed<br/>Fabric SQL DB · dbo.FloorEvents"]
        GSQL["🗄️ OeeGovernance<br/>Fabric SQL DB · dbo.OeeTarget"]
    end

    %% ---------------- OneLake ----------------
    subgraph ONELAKE["OneLake"]
        MIRROR["OneLake mirroring<br/>(auto-Delta)"]
        LH["🌊 ManufacturingLH — schema-enabled<br/>shortcuts @ Tables/dbo/*<br/>Silver · dims · FloorEvent · OeeTarget"]
        MIRROR --> LH
    end

    %% ---------------- Fabric IQ & semantics ----------------
    subgraph SERVE["Fabric IQ & semantic layer"]
        ONT["🕸️ OEEFactoryOntology<br/>entities · relationships · rules · metrics<br/>binds 4 sources · graph"]
        SM["📊 OEEAnalytics<br/>Direct Lake on OneLake<br/>OEE = A × P × Q (DAX)"]
        DA["🤖 OEE Data Agent<br/>ontology as context<br/>KQL · SQL · DAX"]
        SEARCH["🔎 Azure AI Search<br/>36 SOP PDFs (indexed)"]
        KB["📚 Foundry IQ knowledge base<br/>SOP index + ontology"]
        SM -->|measures| ONT
        ONT -->|context| DA
        ONT --> KB
        SEARCH --> KB
    end

    %% ---------------- Agents & reporting ----------------
    subgraph OUT["Agents & reporting"]
        RPT["📈 Power BI report<br/>5 pages incl. Floor Ops"]
        DASH["📟 Real-Time Dashboard"]
        ALERT["📧 Activator<br/>outage email"]
        OPS["🛎️ OEE Operations Agent<br/>ontology rules over the Eventhouse<br/>→ alerts (activity log · Teams)"]
        AGENT["💬 Foundry 'OEE Factory IQ' agent<br/>knowledge base + data agent<br/>evaluated in Foundry"]
    end

    %% ---------------- Flows ----------------
    SIM -->|Event Hubs protocol| ES
    ES -->|route| BRONZE
    APP -->|write| FSQL
    WB -->|UDF MERGE| GSQL

    SILVER -->|mirror| MIRROR
    FSQL -->|mirror| MIRROR
    GSQL -->|mirror| MIRROR

    LH -->|SQL endpoint| ONT
    EH -->|live events| ONT
    GSQL -->|OEE targets| ONT
    LH -->|Direct Lake on OneLake| SM

    SM --> RPT
    EH --> DASH
    ES -->|becomes Fault| ALERT
    EH -->|monitors| OPS
    ONT -.->|"rules"| OPS
    KB --> AGENT
    DA --> AGENT

    %% ---------------- Styling ----------------
    classDef src fill:#0b5394,stroke:#073763,color:#ffffff;
    classDef store fill:#38761d,stroke:#274e13,color:#ffffff;
    classDef lake fill:#1155cc,stroke:#0b3d91,color:#ffffff;
    classDef serve fill:#b45f06,stroke:#7f4005,color:#ffffff;
    classDef out fill:#990000,stroke:#5b0000,color:#ffffff;

    class SIM,APP,WB src;
    class ES,BRONZE,SILVER,FSQL,GSQL store;
    class MIRROR,LH lake;
    class ONT,DA,SM,SEARCH,KB serve;
    class RPT,DASH,ALERT,OPS,AGENT out;
```

Three sources feed Fabric: streaming telemetry, floor issues that operators log, and OEE targets that managers
set from the report. Each lands in its own store, and everything mirrors into OneLake, where lakehouse
shortcuts bring it together under `ManufacturingLH/Tables/dbo`. The semantic model reads that one surface. The
ontology binds the plant's structure there too, but reads live events straight from the Eventhouse, OEE
targets straight from the `OeeGovernance` database, and its KPIs from the semantic model. The agents, reports,
and alerts at the bottom consume them.

## The data path

- **The simulator** models 5 lines and 30 stations with bounded buffers, cascading faults, part traceability,
  and maintenance work orders. Every station reports every 10 seconds. It sends three event types (machine
  telemetry, part events, and maintenance events) to the Eventstream's custom endpoint over the Event Hubs
  protocol. Their contracts are in `eventschemas/`, published as an Event Schema Set.
- **The Eventstream** routes each event type to its own Bronze `*_Raw` table in the `ManufacturingEH`
  Eventhouse.
- **Update policies** build the Silver tables: they add the shift, status flags, and the station that caused
  an idle, and cascade the keyed `WorkOrders`, `Parts`, and `PartPasses` tables. Streaming ingestion is on, so
  the policies only filter and project. An update policy can't look up another table while streaming ingestion
  is on.
- **OneLake mirroring** exports the Silver, derived, and reference tables as Delta every 5 minutes, and the
  lakehouse shortcuts them.

## One definition per KPI

OEE is computed when you query it, from the same definitions in each layer. There's no precomputed OEE table.

| KPI | Definition |
|---|---|
| Availability | Running samples ÷ all samples, so starved and blocked time counts against it |
| Performance | Ideal cycle time ÷ actual cycle time over running samples, capped at 100% |
| Quality | Parts completed ÷ (completed + rejected) |
| OEE | Availability × Performance × Quality |

| Layer | Where it's defined |
|---|---|
| Eventhouse | `OeeFacts()` returns additive counts per time bucket; `OeeKpis()` turns them into ratios at any grain |
| Semantic model | The measures in `powerbi/OEEAnalytics.SemanticModel/definition/tables/_Measures.tmdl` |
| Ontology | The `OeeScorecard` metrics reference the semantic model's measures by name, so they aren't defined again |

`scripts/6-publish-ontology.py` checks that every measure the ontology references exists in the semantic model.

One check differs on purpose. The operations agent's station escalation follows the plant's policy and leaves
starved and blocked time out of Availability, because that time counts against the station that caused it. With
the measured definition, about half the stations would escalate at any moment because of their neighbors.

## Analytics and write-back

- **Direct Lake on OneLake.** The `OEEAnalytics` model reads the lakehouse's Delta tables directly, with no
  import and no SQL endpoint in the query path. Direct Lake relationships are single-column, so stations are
  keyed on `device_id`.
- **OEE targets.** The report's **Update OEE** button calls the `set_oee_target` user data function, which
  upserts a row in the `OeeGovernance` SQL database. The ontology reads the table straight from the database.
  The database also mirrors to OneLake, and a shortcut lets the model's `Target OEE` measure read it minutes
  later.
- **Floor issues.** The Floor Ops Console writes only to its own SQL database: a deployed Fabric App signs users
  in with Fabric and can't reach other data sources without an app registration. Fabric does the integration
  instead. The database mirrors to OneLake, and the issues join the model on line, station, and shift.
- **Outage alerts.** The Activator watches the Eventstream itself, so it emails as soon as a station's status
  becomes `Fault`.

## Fabric IQ

The ontology is where the plant's meaning lives: what a station, a work order, or a part pass is, how they
relate, what each business rule requires, and which measure defines each KPI. It has 18 entity types in five
namespaces, 16 relationships, 13 rules, and 28 metrics, authored as TMDL in `ontology/` and published by
script 6. Nothing is edited in the portal except materializing the graph.

- **Each entity reads the source that owns its data.** The ontology binds all four kinds of source the demo has:

    | Source | Binding | Entities |
    |---|---|---|
    | `ManufacturingLH` lakehouse | Direct Lake, through its SQL analytics endpoint | The plant's structure and records: lines, stations, machines, machine types, shifts, schedules, parts, work orders, technicians, fault codes, SOPs, policies, and floor issues |
    | `ManufacturingEH` Eventhouse | DirectQuery (KQL) | Machine telemetry, work order steps (`MaintenanceEvent`), and part passes (`PartPass`) |
    | `OeeGovernance` SQL database | Direct Lake, through its SQL analytics endpoint | `OeeTarget` |
    | `OEEAnalytics` semantic model | DirectQuery to the model | `OeeScorecard`, whose metrics are the model's measures |

- **Live events come straight from the Eventhouse.** Each machine's telemetry is a set of time-series properties
  whose latest value is its current state, and the keyless `PartPass` and `MaintenanceEvent` entities carry part
  genealogy and work order timelines. None of them waits for the OneLake export, so whether a work order is
  open is current.
- **KPIs are the model's measures.** `OeeScorecard` references 28 `OEEAnalytics` measures with
  `EXTERNALMEASURE`, so the ontology shows each KPI's DAX and evaluates it in the model. Script 6 copies each
  measure's description from the model and stops if one no longer exists.
- **The graph holds the plant's structure.** The graph doesn't load entities bound to the Eventhouse or the
  semantic model, so it covers lines, stations, parts, work orders, and documents, and leaves telemetry, events,
  and KPIs to their sources.
- **Rules come from the SOPs.** The 13 rules restate the escalation, quarantine, maintenance, safety, and
  attribution policies in the SOP documents, tied to the properties they reference. The data agent gets them in
  its instructions, and the operations agent applies the alert rules.

## The agents

| Agent | Answers from | Notes |
|---|---|---|
| **OEE Data Agent** (Fabric) | The ontology, as context | The ontology tells it what each entity means and which source holds it, and it writes KQL for the Eventhouse, SQL for the lakehouse, or DAX for the semantic model. The Eventhouse and the lakehouse are mounted under the ontology with their own instructions, and the Eventhouse's example queries inline `OeeFacts()` and `OeeKpis()`, because the query generator can't see stored functions. Data agents can't query a SQL database bound to an ontology, so it reads OEE targets from the model. |
| **OEE Factory IQ** (Foundry) | A Foundry IQ knowledge base over the SOP index and the ontology, plus the data agent | Numbers go to the data agent, and procedures, rules, and plant design go to the knowledge base. It acts as the signed-in user. |
| **OEE Operations Agent** (Fabric) | The Eventhouse, with the ontology's alert rules | An operations agent over an ontology checks only a property's latest value, and these rules count events or compute rates over a window. Each rule has a `Rule…()` check function in the Eventhouse. |

Script 12 evaluates the Foundry agent on 25 persona questions, with deterministic checks for routing and facts
next to Foundry's AI judges.

## Not included

- **A schema-aware Eventstream.** The event contracts are published as an Event Schema Set, but associating
  them with a stream needs a new Eventstream created in the portal.

## Go deeper

- [Ontology README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/ontology/README.md): the model,
  its bindings, and how to change it.
- [Agent README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/agent/README.md): the Foundry agent's
  tools, routing, and identity.
- [Evaluation README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/agent/evals/README.md): the
  question set, the results of each agent version, and what they found.
- [Floor Ops Console README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/app/README.md): the
  Fabric App's layout and development.
