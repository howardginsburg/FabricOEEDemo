# Repository map

| Path | What's there |
|---|---|
| [`simulator/FabricOEESimulator.Wpf/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/simulator/FabricOEESimulator.Wpf) | The Windows WPF simulator: the simulation engine, the telemetry senders, and the factory-floor UI. `simulator.yaml` holds the lines, stations, and demo scenarios. |
| [`eventschemas/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/eventschemas) | The simulator's event contracts (CloudEvents and JSON Schema), published as the OEE Telemetry Events Event Schema Set. |
| [`dashboard/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/dashboard) | The Real-Time Dashboard template that script 1 imports. |
| [`powerbi/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/powerbi) | The `OEEAnalytics` Direct Lake semantic model (TMDL) and report (PBIR), and in `translytical/`, the `OeeTarget` schema and the `set_oee_target` user data function. |
| [`app/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/app) | The Floor Ops Console Fabric App. See its [README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/app/README.md). |
| [`ontology/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/ontology) | The `OEEFactoryOntology` TMDL (entities, relationships, rules, metrics, and bindings) and the saved GQL graph queries. See its [README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/ontology/README.md). |
| [`knowledge/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/knowledge) | The 36 SOP and policy PDFs, and their Markdown sources in `knowledge/source/`. |
| [`agent/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/agent) | The OEE Factory IQ agent's system prompt and knowledge notes, and in `evals/`, the persona question set and the evaluation results. See its [README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/agent/README.md). |
| [`scripts/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/scripts) | The setup scripts. See [Scripts](scripts.md). |
| [`docs/`](https://github.com/howardginsburg/FabricOEEDemo/tree/main/docs) | This site's pages and screenshots. `mkdocs.yml` at the root configures the site, and `.github/workflows/docs.yml` publishes it to GitHub Pages. |
| [`eventstream_topology.json`](https://github.com/howardginsburg/FabricOEEDemo/blob/main/eventstream_topology.json) | A snapshot of the deployed Eventstream's sources, filters, and destinations, for reference. The scripts don't use it. |

## Build this site locally

The site is built with [Zensical](https://zensical.org) from `docs/` and `mkdocs.yml`:

```bash
python3 -m venv .venv-docs
source .venv-docs/bin/activate
pip install -r docs/requirements.txt
zensical serve
```

Then open `http://localhost:8000`. A push to `main` that changes the site publishes it to GitHub Pages.
