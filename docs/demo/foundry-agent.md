# OEE Factory IQ agent

OEE Factory IQ is a Microsoft Foundry agent for the plant's six personas. It combines the plant's procedures and
policies with its live data in one answer: a Foundry IQ knowledge base searches the SOPs and the ontology, and
the OEE Data Agent answers the numbers.

!!! info "Needs"
    Setup steps [9](../setup/foundry-agent.md), and [10](../setup/evaluate.md) for the evaluations

## What to show

In the [Foundry portal](https://ai.azure.com), turn on **New Foundry** and open the project. Then open
**Agents** > **oee-factory-iq**. Just before you ask the first question, fire **Fault now** on the Line-D
Curing-Oven in the simulator: it raises a Thermocouple-Drift fault, and the work order stays open for about 10
minutes. Ask in the playground:

1. "The Line-D Curing-Oven just raised a Thermocouple-Drift fault. What's the corrective procedure, and is there
   an open work order?" The procedure comes from the Curing-Oven's SOP, with citations, and the open work order
   from the data agent, which reads it live from the Eventhouse.
2. "Walk me through the LOTO procedure for the Line-B Hydraulic-Press." This follows the repeat faults.
3. "If Line-A CMM-Inspection rejects exceed 8% in an hour, what do I do?"

![The agent's answer: the Curing-Oven SOP's corrective procedure with citations, and the open work order read live from the Eventhouse](../assets/screenshots/demo/foundry-agent.png){ width="420" }

!!! quote "What to say"
    "The technician asks one question and gets the procedure and the current state of the machine together, with
    sources. The agent acts as the person asking, so Fabric's permissions still apply."

## How we know it's good

Every version of the agent answers the same 25 persona questions. A script checks that it used the right tools
and that its answers contain the required facts, and AI judges in Foundry grade intent, task adherence, tool
calls, groundedness, and completeness. Open **Evaluations** > **oee-factory-iq persona set** in the project to
compare versions.

![The persona set evaluation, with a run for each agent version](../assets/screenshots/demo/foundry-evals.png)

!!! quote "What to say"
    "We don't guess whether a prompt change helped. Each version runs the same evaluation, and we compare the
    scores side by side."

The questions are on the [Sample questions](sample-questions.md) page, and the
[evaluation README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/agent/evals/README.md) shows what
each round found and fixed.
