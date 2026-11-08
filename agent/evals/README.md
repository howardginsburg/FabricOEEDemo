# Evaluating OEE Factory IQ

`scripts/12-evaluate-agent.py` evaluates the `oee-factory-iq` Foundry agent on a fixed set of persona questions, and publishes each run to a Foundry evaluation so agent versions can be compared side by side. This page explains what it checks, how to run it, and what the evaluations found.

## How it works

1. **Load the question set.** [cases.json](cases.json) holds 25 questions from six personas: Corp Exec, Plant Manager, Line Manager, Maintenance Tech, Quality Worker, and Reliability Engineer. Each case lists the knowledge the answer needs, the facts it must contain, and a reference answer. The file's `description` field documents the format.
2. **Resolve data facts.** Values that exist only in the plant's reference data, like stations per process family, come from each case's `facts_kql` query against `ManufacturingEH` at run time. The question set never copies seed values, so it can't drift from the data.
3. **Ask the agent.** The script asks every question as the signed-in user, three at a time, with background responses. The agent's Fabric IQ tools and the knowledge base's ontology source act on the caller's behalf, which a server-side agent-target evaluation can't do. So the responses are generated locally and judged in Foundry.
4. **Check locally.** Two deterministic checks run on each response:
   - **route**: the agent called a tool for every knowledge source the case needs;
   - **facts**: the answer contains every required fact.
5. **Judge in Foundry.** The script uploads the responses as a project dataset and adds a run to the evaluation **oee-factory-iq persona set**, which it creates on first use. The run's testing criteria are the two local checks (as string checks) and five built-in AI judges.
6. **Report.** It prints a per-case scorecard and the run's report URL, and saves the responses, checks, and judge results to `agent/evals/results/` (git-ignored).

| Criterion | Kind | What it checks |
|---|---|---|
| route | string check | The agent consulted each knowledge source the case lists: `sop` through the knowledge base, `ontology` through the knowledge base or the data agent, `data` through the data agent. |
| facts | string check | Every required fact appears in the answer. Matching ignores case, dash style, and Markdown emphasis; a list accepts any of its alternatives; `re:` facts are regular expressions. |
| intent | `builtin.intent_resolution` | The answer resolves what the user asked. |
| task | `builtin.task_adherence` | The answer follows the agent's own instructions (the system prompt goes in with the question). |
| tools | `builtin.tool_call_success` | Every tool call succeeded. |
| grounded | `builtin.groundedness` | The answer's claims are supported by the tool results in the conversation. |
| complete | `builtin.response_completeness` | The answer covers the case's reference answer. |

The judge is `gpt-5.4-mini`, deployed by `scripts/8-setup-foundry.sh`. It's generally available, has consumption quota, and is a different model from the agent's `gpt-5.5`, so the agent isn't graded by itself.

## Run it

```bash
python3 scripts/12-evaluate-agent.py \
  --foundry-resource <FOUNDRY_RESOURCE_NAME> \
  --project <FOUNDRY_PROJECT_NAME> \
  --fabric-workspace "<FABRIC_WORKSPACE>"
```

| Option | Use |
|---|---|
| `--case <id>` / `--persona <name>` | Run a subset (repeatable). |
| `--skip-foundry` | Run the local checks only. |
| `--resubmit <results.json>` | Check and judge saved responses again without asking the agent, for example after changing a case's facts. |
| `--write-samples` | Regenerate [docs/demo/sample-questions.md](../../docs/demo/sample-questions.md) from the question set. |
| `--knowledge tools` | Evaluate an agent built with `scripts/10-setup-foundry-agent.py --knowledge tools`. |

Each run takes about 20 minutes to ask the 25 questions and another 5–10 minutes to judge. The script exits with status 1 if any response errored or the Foundry run failed.

**Capacity cost.** A full run asks the data agent about 30–40 times, and each question uses 65,000–100,000 prompt tokens, about 7,000–10,000 CU-seconds on the Fabric capacity. That's a third to a half of an F8's daily capacity per run, and three full runs in one afternoon throttled it. While iterating, run subsets with `--case` or `--persona`, re-judge saved responses with `--resubmit`, and keep full runs for checkpoints (or scale the capacity up while iterating). The judges run in Foundry and don't use Fabric capacity.

When you change the testing criteria or the item schema, bump `CRITERIA_VERSION` in the script. The next run then starts a new evaluation, instead of adding a run whose criteria differ from the earlier ones.

## Results

Each row is one run of the 25 cases (passed out of 25). All runs are in the **oee-factory-iq persona set** evaluation in the Foundry portal (project → Evaluations).

| Agent version | Changes | route | facts | intent | task | tools | grounded | complete |
|---|---|---|---|---|---|---|---|---|
| v4 | Baseline | 22 | 18 | 22 | 22 | 22 | 24 | 18 |
| v5 | Routing, bottlenecks, latest-hour windows, refusal policy | 23 | 21 | 23 | 21 | 22 | 23¹ | 22 |
| v6 | Knowledge base runtime budget and retrieval instructions, reject-rate trends, work orders for stations that are down | 25 | 23 | 25 | 22 | 25 | 25 | 25 |
| v7 | Six personas in the prompt, pause and quarantine thresholds for line managers; harness passes full tool results to the judges | 25 | 25 | 25 | 20 | 23 | 25 | 24 |
| v8 | Citation policy names the data agent's sources; example queries for the OEE escalation check and starved/blocked root cause | 25 | 24 | 25 | 22 | 25 | 24 | 25 |
| v9 | Escalation status asked as its own question; data agent: root cause in the ontology, duration rule checks, condensed instructions | 24² | 23 | 24 | 22 | 24 | 24 | 24 |
| v10 | Below target compares governed OEE, asked once; latest-hour example query adds the biggest loss and the 60% flag | 25 | 25 | 25 | 24 | 24 | 25 | 24 |

¹ One groundedness result was a judge connection error, not a failure.
² `lm-line-b-down` failed every criterion because the knowledge base's ontology source returned BadGateway, a service error rather than an agent failure.

v12 moved the data agent to the ontology as its context: the ontology now binds the Eventhouse, the lakehouse, the `OeeGovernance` SQL database, and the `OEEAnalytics` model, and the agent writes KQL, SQL, or DAX for the source each entity is bound to. An 8-case subset over the routes that changed (`exec-lines-below-target`, `pm-oee-latest-hour`, `lm-line-b-down`, `lm-line-d-starved-blocked`, `mt-thermocouple-drift`, `qw-part-genealogy`, `rel-technician-resolved`, `rel-mttr-mtbf`) passed every criterion in 7 cases. In `exec-lines-below-target`, the data agent's escalation-duration query hit a type error and the agent said it couldn't confirm the tier, which task adherence and tool-call success count; the same question succeeded when asked again, and the case was flaky before (v7, v9). Version 11 was a portal save (reasoning effort and voice settings) and wasn't evaluated.

In v10, 23 of the 25 cases passed every criterion and no response failed. The task and completeness judges marked `lm-line-b-down` down for adding each faulted station's fault type and open work order, which the system prompt asks for. In `lm-aoi-trend`, the data agent's first query failed before it recovered, which tool-call success counts.

In v6, 21 of the 25 cases passed every criterion and no response failed. Of the four remaining failures:

- `qw-part-genealogy` named the stations as "Line-C station 6" rather than `line-c-station-6`. The case now accepts both forms.
- `rel-technician-resolved` failed task adherence because the judge said the answer had no supporting tool result, but the data agent's result in the transcript matches the answer exactly.
- `lm-aoi-trend` didn't mention the policy's 7% pause threshold, though it gave the 8% quarantine rule. The judge also called the calibration steps unsupported: the knowledge base result was cut at the harness's old 12,000-character limit, which is now 40,000.
- `lm-line-b-down` failed task adherence for listing more open work orders than the question needed.

In v7, every case passed routing, facts, intent, and groundedness. Task adherence and tool-call success account for the rest: findings 7 and 8 below.

## What the evaluations found

Each finding below came from a failed criterion, and each fix was verified by a later run.

1. **Knowledge base timeouts** (v4, v5). Asked a question that needs live numbers, the knowledge base's ontology source runs a live natural-language query over the ontology's data, which can run until its own 100-second timeout. The agent's knowledge base tool doesn't set a retrieve runtime, so the service default of 90 seconds failed the whole response. That happened for "Which lines are below target, and what does the escalation policy require?", and even for "If Line-A CMM-Inspection rejects exceed 8% in an hour, what do I do?" because it names live values. **Fixes (v6):**
   - The knowledge base stores a 150-second `retrieveDefaults.maxRuntimeInSeconds`, so a slow ontology query degrades to an SOP-only answer.
   - Its retrieval instructions send procedure, condition, and KPI questions to the SOP source only. The knowledge base answered the CMM question in 10 seconds instead of 85.
   - The system prompt shows the agent how to split a combined question so the knowledge base gets only the policy part.
2. **Empty "last hour" windows** (v4). With the simulator stopped, the data agent's `ago(1h)` windows found no data. **Fix (v5):** the data agent's instructions and an example query anchor "the latest hour of data" to the latest event.
3. **Bottlenecks derived from data** (v4, v5). The agent, and then the knowledge base's ontology source, named the station with the worst OEE or the longest cycle time as the bottleneck, instead of the design constraint documented in `Production_Lines_Reference.pdf`. **Fixes:** a Bottlenecks section in the system prompt (v5) and retrieval instructions that keep bottleneck questions on the SOP source (v6).
4. **Technician names refused** (v4). The privacy refusal in the system prompt blocked work-order records. **Fix (v5):** the refusal policy says that technician names and IDs in plant data are operational records.
5. **Reject-rate trend failures** (v5). The data agent's generated KQL for a station's reject-rate trend failed with semantic errors. **Fix (v6):** an example query for an hourly reject-rate trend, anchored to the latest part pass.
6. **Station state without work orders** (v5). A list of stations in Fault or Maintenance gave no fault type or work order. **Fix (v6):** the system prompt asks for both, from the data agent.
7. **Sources the judge couldn't place** (v6, v7). The data agent's ontology source reads the ontology's tables in the `ManufacturingLH` lakehouse and says so. The agent repeated that query description as its source, but the system prompt listed only the semantic model and the Eventhouse as data agent sources, so the task adherence judge flagged the answers as resting on an unapproved source. **Fix (v8):** the system prompt names the lakehouse as where the ontology's data lives, and the citation policy has the agent cite the data agent and the source it reported without restating its query.
8. **Rule checks and root causes from the data agent** (v7, then smoke tests after v8). Asked whether a line's OEE had stayed below 60% for more than 15 minutes, the data agent first queried the semantic model, which has no time dimension. Once routed to the Eventhouse, its orchestrator prescribed its own method ("at least four consecutive 5-minute buckets in the latest hour"), and the generated run detection grouped the buckets wrongly, so it named the wrong lines. Asked which station caused the most starved or blocked time on Line-D, it counted idle samples by the idle station instead of the station that caused them: the ontology, which it asked first, didn't model the cause. **Fixes (data agent, after v8):**
   - An example query measures how long each line or station has stayed below 60%: from the 5-minute bucket after its last one at or above 60%, where a bucket in which it was down counts as OEE 0. The instructions tell the orchestrator to pass rule checks to the Eventhouse in the user's words, without prescribing a method.
   - The ontology's Machine entity has a `root_cause_device_id` time-series property, and rule StarvedBlockedRootCause says the idle time counts against that station, so the ontology answers root-cause questions too.
   - The semantic model's instructions say it can't answer time-window questions, and a source that can't answer hands the question to the next one that has the data.
   - Time in a state is counted as samples × 10 seconds. A query that subtracted timestamps between samples reported 37,000 "minutes" across gaps when the plant wasn't running. The ontology's SQL did the same when the orchestrator asked it for minutes (215,735 instead of about 1,200), so the orchestrator asks the ontology for sample counts and converts them itself. Its answers also had the direction backwards ("starves upstream"); the instructions now say a station starves the stations after it and blocks the ones before it, with an example sentence.
9. **Escalation tier read from full-history OEE** (v8 after the data agent fixes, v9). Asked "Which lines are below target, and what does the escalation policy require?", the Foundry agent asked the data agent for OEE, targets, and the escalation status in one question. The data agent answered from the semantic model and reported every line below 60% for more than an hour, Line-A included (its latest five-minute OEE was 0.613). **Fix (v9):** the system prompt makes "has an escalation rule fired" a separate question, in the wording the data agent's example query matches. In v9 the agent then asked a third time for "below target in the latest window", got a different answer, and reported only two lines. **Fix (v10):** below target compares the governed OEE with each line's target unless the user names a window, asked once, next to the escalation check.
10. **Latest-hour OEE with targets** (v9). The agent asked the data agent for latest-hour OEE together with targets and the biggest loss. The generated KQL returned raw samples instead of KPIs, so the agent fell back to the full-history semantic model, which the task judge caught. **Fix (v10):** the latest-hour example query also returns the biggest loss, a below-60% flag, and the line name, and the Eventhouse instructions again say to follow the OEE example queries exactly.

The data agent's instructions were also condensed in v9 (11,359 to 9,477 characters, with every rule kept) to reduce its token use. A question costs 65,000–100,000 prompt tokens, and the spread comes from how many internal steps the service takes (each adds about 33,000 tokens), not from the instructions. Where a question took the same path before and after, the condensed instructions saved about 2%.

The harness also changed while the question set was being calibrated:

- Station facts match both `line-a-station-5` and "Line-A station_position 5".
- `responses.retrieve` is retried, because it can return 404 right after a background `responses.create`.
- Groundedness replaced `builtin.tool_output_utilization`, which failed answers whose tool results were plain text.
- Records whose response failed still carry the agent's tool definitions. Without them, the run fails with `MissingRequiredDataMapping`, since evaluators that support a field require it to be mapped when the items carry it.
- Tool results sent to the judges are cut at 40,000 characters instead of 12,000, so the judges see the knowledge base's full answers.
- The results file is written before judging as well as after, and polling the judge run retries transient errors. A slow `az` token refresh had crashed the v10 run after its 25 answers, which were then read back from the Foundry run.
- Two facts that were stricter than the SOPs were dropped, and station facts accept "Line-C station 6" as well as `line-c-station-6`.

## Known issues

- **Data agent miscount.** In the v5 run, the data agent reported Surface 7 and Inspection 6 stations instead of 6 and 7. The Eventhouse, the lakehouse, the ontology binding, and the semantic model all agree on 6 and 7, and v6 answered correctly, so it was a one-off query-generation error. Watch `rel-process-families`.
- **SOP inconsistencies.** `Shift_Handover_Checklist.md` lists three shifts (A, B, C) while the plant data has Day and Night. `OEE_Targets_and_Escalation.md` lists line targets of 78/72/75/70/73%, while the governed `OeeTarget` values set through the report's write-back are 65/73/75/75/75%. The cases don't depend on either; the agent reports the governed targets.
- **Run-to-run variation.** The agent and the AI judges are both nondeterministic, and the judges sometimes miss evidence that's in the transcript. Treat a change of one or two cases as noise unless it repeats in another run, and read the judge's reason before changing the agent.
