# Troubleshooting

Every setup script is safe to re-run, and re-running the script for the failed step is usually the fix.

## Setup scripts

**A script fails with path errors or request-body errors on Windows.**
:   Run it under WSL. Under Git Bash, `az` resolves to a wrapper that breaks the scripts' request bodies. See
    [Prerequisites](prerequisites.md#tools).

**A script can't find your workspace or subscription.**
:   WSL and Windows keep separate Azure CLI sign-ins. Run `az login` inside WSL, with `--tenant <TENANT_ID>` if
    your account has several tenants, and check `az account show`.

## No data

**The Real-Time Dashboard is empty, or the latest events are old.**
:   Check, in order: the simulator is running and shows **Stop**; the Eventstream is published; and its
    destinations are **Running**, not **Paused**. See [Check the Eventstream](fabric-foundation.md#check-the-eventstream).

**Reference data, such as stations or shifts, is missing for a few minutes.**
:   Re-running step 1 reseeds the reference tables, and their OneLake copies are empty for about 7 minutes
    until mirroring catches up. The lakehouse, the ontology, the data agent, and the report show no reference
    data until then.

**The lakehouse lists tables under `Tables/Unidentified`.**
:   The `ManufacturingLH` lakehouse was created without schemas, so the `dbo` shortcuts don't resolve. Step 1
    creates it with schemas; if you created it yourself, delete it and re-run step 1.

## Power BI

**The Target OEE card is blank, or the Update OEE button is missing.**
:   Step 3 hadn't finished when you ran step 5. Re-run [step 3](write-back.md), and then
    [step 5](power-bi.md).

**Update OEE fails.**
:   Check the function's `OeeGovernance` connection; see the note at the end of [step 3](write-back.md).

**The reframe at the end of step 5 fails.**
:   Right after a first deployment, a newly mirrored table can still be loading. The report works anyway,
    because Direct Lake reads OneLake when you query it. Re-run step 5 later, or select **Refresh** on the
    semantic model in the portal.

## Activator

**The outage email doesn't arrive.**
:   Check that telemetry is flowing (see [No data](#no-data)), choose **Fault now** on a station in the
    simulator, and check that the recipient is a mailbox in your tenant. See [step 6](activator.md).

## Fabric IQ

**A new ontology property doesn't appear in the graph.**
:   The graph keeps the properties it was materialized with. Run **Manage graph** again; see
    [step 7](fabric-iq.md#materialize-the-graph).

**The ontology's records trail the Eventhouse.**
:   The ontology reads machine telemetry, work order steps, and part passes live from the Eventhouse. The plant's
    records, such as work orders as raised and the stations, come from the lakehouse, which trails the Eventhouse
    by the OneLake mirror's latency, up to 5 minutes.

    Hours behind means the lakehouse's SQL analytics endpoint, which the ontology reads through, has stopped
    syncing: it does that after 15 minutes without queries. Open `ManufacturingLH`, switch to its **SQL analytics
    endpoint**, and select **Refresh**; the tables catch up within a minute or so.

**The data agent doesn't use a change to the ontology.**
:   The data agent reloads the ontology's context every 10 minutes. Wait, or open the agent, select the ontology's
    **...** menu, and refresh its context.

**The data agent can't answer KPI questions from the semantic model.**
:   Check that the ontology includes `OeeScorecard` (script 6 leaves it out until `OEEAnalytics` exists) and that
    you have Read and Build permissions on the model. The agent reaches a source only through entity properties
    bound to it, which is why `OeeScorecard` binds the model's `_Measures[Value]` column.

**KPIs in the report or from the agents are hours or days old.**
:   The semantic model stopped framing, which can happen when the capacity was throttled. Re-run
    [step 5](power-bi.md), which reframes it, or select **Refresh** on `OEEAnalytics`.

**An ontology question returns nothing after about a minute.**
:   Questions that compute KPIs for many stations at once can time out. Ask for one line, or ask the data agent.

**The data agent finds no data for "the last hour".**
:   The simulator isn't streaming. Ask about "the latest hour of data" instead; the agent anchors that window
    to the latest event.

## Agents

**The operations agent doesn't send a message.**
:   Open the agent and select **View activity**. If the alert is there, the agent sent it; check that the
    recipient has the **Fabric Operations Agent** Teams app. If it isn't, check that you started the agent
    (`--start`) and that the rule's condition has held long enough. The agent checks about every 5 minutes, and
    some rules need a condition to last: a long outage fires only after 5 minutes. If a rule never alerts while
    its `Rule…()` function in `ManufacturingEH` returns rows with `fired` true, run script 11 again with
    `--generate-playbook`.
    See [Operations agent](../demo/operations-agent.md).

**The Foundry agent fails with "Operation exceeded the maximum runtime of 90 seconds".**
:   The knowledge base has no retrieve budget, so the service's 90-second default applies. Re-run
    [script 10](foundry-agent.md#create-the-knowledge-base-and-the-agent); it sets a 150-second budget.

**The Foundry agent can't reach the ontology or the data agent.**
:   The agent acts as the signed-in user, who needs read access to the ontology, the data agent, and their
    sources. Service principals aren't supported.

**The knowledge base fails with a payment-required error.**
:   The search service has used this month's free agentic retrieval allowance. Enable the standard plan; see
    [the note in step 9](foundry-agent.md#create-the-knowledge-base-and-the-agent).

## Azure

**Step 9 reports that a model has no quota.**
:   Script 8 prints the options to use another model or version. See
    [Create the Foundry resource and models](foundry-agent.md#create-the-foundry-resource-and-models).

**Script 8 fails with "unrecognized arguments".**
:   Your Azure CLI is older than 2.67. Run `az upgrade`.

**AI Search fails with `InsufficientResourcesAvailable`.**
:   The region has no AI Search capacity. Add `--search-location <OTHER_REGION>` to script 9.

**Script 9 stops because public network access is still Disabled, or uploads fail with 403 "blocked by network rules".**
:   An Azure Policy disabled public network access on the storage account. Script 9 tries to turn it back on, but
    a policy that enforces the setting switches it straight back. Have an administrator exempt the account or
    turn public network access on, then run script 9 again. You can turn it off once script 9 finishes: the index
    keeps the SOP text, so the agent never reads the storage account.

**The indexer fails with 403 right after the search service is created.**
:   The search service's access to storage can take a few minutes to apply. Script 9 retries; if it still
    fails, wait a few minutes and run it again.

## Capacity

**Requests fail with `CapacityLimitExceeded` or HTTP 429 `RequestBlocked`.**
:   The capacity is throttled, usually by agent questions, evaluation runs, or graph loads. See
    [Capacity and cost](../reference/capacity.md). Throttling can also pause the Eventstream's destinations, so
    once it clears, [check the Eventstream](fabric-foundation.md#check-the-eventstream).
