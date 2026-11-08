# OEE Data Agent

The OEE Data Agent answers questions in plain language, with the `OEEFactoryOntology` ontology as its context.
The ontology tells it what each thing means and which source holds it, and the agent writes the query in that
source's language: KQL for live telemetry, work orders, and anything over a time window in the Eventhouse; SQL
for the plant's records in the lakehouse; and DAX for the governed KPIs and OEE targets in the semantic model.

!!! info "Needs"
    Setup step [7](../setup/fabric-iq.md)

## What to show

Open **OEE Data Agent** in the workspace and ask:

1. "Which station caused the most starved or blocked time on Line-D, and why?" It names line-d-station-5, the
   Curing-Oven and the line's slowest station, with the starved and blocked time it caused, from the Eventhouse.
   The agent counts idle time against the station that caused it, as the ontology's rule says, not against the
   station that sat idle.
2. "What is OEE by station on Line-D?" It evaluates the semantic model's OEE measures by station, the same numbers
   the report shows.
3. "Which stations are on Line-C, and what machine type runs at each?" It answers from the lakehouse.
4. "What should happen when a line's OEE falls below its target?" The answer comes from the ontology's rules.

![The data agent naming the station that caused Line-D's starved and blocked time](../assets/screenshots/demo/data-agent.png)

Expand the steps under an answer, open a step, and select **Show input**. You see which source answered and the
query it ran: KQL for the first question, DAX for the second, and SQL for the third.

!!! quote "What to say"
    "Nobody had to know which table holds what. The agent starts from the business model, and the model tells it
    where each answer lives: the Eventhouse for what's happening now, the lakehouse for the plant's records, and
    the semantic model for the KPIs. You can see exactly what it ran."

More questions, grouped by persona, are on the [Sample questions](sample-questions.md) page. The ones whose
answer needs only the data agent or the ontology work here too.
