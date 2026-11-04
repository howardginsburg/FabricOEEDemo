# Capacity and cost

The demo was built on an F8 capacity, which has 691,200 CU-seconds a day. An F8 runs the demo comfortably. What
exhausted it while the demo was being built were development loops: repeated evaluation runs, ontology
publishes, and playbook generations.

## What uses the capacity

Over two weeks, the [Capacity Metrics app](https://learn.microsoft.com/fabric/enterprise/metrics-app) showed:

- **The live pipeline is light.** The Eventstream, the Eventhouses, the lakehouse, the semantic model, the
  Real-Time Dashboard, Activator, and the Floor Ops SQL database used about 92,000 CU-seconds in total, about
  13% of one day.
- **The Fabric IQ items are billed per use**, and they accounted for 96% of the usage:

| Item | How it's billed | Measured here |
|---|---|---|
| OEE Data Agent | AI tokens, 100 CU-s per 1,000 input tokens | About 66,000 prompt tokens per question, about 7,000 CU-s |
| OEE Operations Agent | Reasoning tokens at four times the data agent's rates | About 625,000 CU-s, nearly all from the playbook generations made while building it |
| Ontology graph | 10 CU-s per second of graph compute | About 565,000 CU-s for about 2¼ hours of ingestion and queries |
| OEEFactoryOntology | Discovery (1,000 CU-s per definition read) and AI reasoning: preview, not billable yet. Its child graph and Eventhouse: billable | About 578,000 CU-s, mostly not billable |

## Keep it in budget

- **Evaluations.** A full run of script 12 uses about a third of an F8's day, because every question reaches
  the data agent. Run subsets with `--case` or `--persona`, and re-judge saved responses with `--resubmit`.
  See [Evaluate the agent](../setup/evaluate.md).
- **The graph.** Every ontology publish reloads the data bound to the graph, and every GQL query wakes it. So
  script 6 doesn't publish an unchanged ontology, and it re-checks the saved GQL queries only when they change
  or with `--refresh-graph`. Re-running script 1 doesn't wake the graph.
- **The operations agent.** Generate its playbook once, with nothing else running, and keep the agent stopped
  outside demos. The agent also writes each alert with AI, so its rules alert once per episode rather than on
  every check.
- **The ontology in the portal.** An open ontology re-reads its definition about every 20 minutes. That isn't
  billable yet, but close the ontology when you're done.
- **Between demos**, stop what's running and pause the capacity. See [Clean up](../setup/clean-up.md).

## Throttling

Throttling shows up as `CapacityLimitExceeded`, or as HTTP 429 `RequestBlocked`. Pausing and resuming the
capacity clears it at once, but the pause bills the remaining smoothed usage immediately: it moves the cost
rather than avoiding it. Preview usage that isn't billable doesn't count toward throttling.

For a heavy session, such as an evaluation run or a long agent demo, you can scale the capacity up in the Azure
portal for the session and back down afterwards.
