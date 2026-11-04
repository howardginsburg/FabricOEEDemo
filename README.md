# Fabric OEE Demo

A real-time **Overall Equipment Effectiveness (OEE)** demo on Microsoft Fabric. A Windows simulator runs a factory
floor of 5 production lines and 30 stations and streams its telemetry into Fabric, where an Eventhouse, a
Real-Time Dashboard, a Direct Lake Power BI report, Activator alerts, a Fabric IQ ontology, Fabric data and
operations agents, and a Microsoft Foundry agent all work from the live stream.

![The Executive OEE page of the Power BI report](docs/assets/screenshots/demo/report-executive.png)

## Documentation

**<https://howardginsburg.github.io/FabricOEEDemo/>**

- [Setup](https://howardginsburg.github.io/FabricOEEDemo/setup/): deploy the demo step by step, from the
  prerequisites to the Foundry agent.
- [Demo](https://howardginsburg.github.io/FabricOEEDemo/demo/): what to show and what to say, with screenshots and
  a run of show.
- [How it works](https://howardginsburg.github.io/FabricOEEDemo/how-it-works/): the architecture and the design
  behind it.
- [Reference](https://howardginsburg.github.io/FabricOEEDemo/reference/scripts/): the scripts, capacity and cost,
  and a map of this repository.

## Quick start

On Linux, macOS, or WSL, with the Azure CLI signed in and a Fabric workspace on a capacity:

```bash
git clone https://github.com/howardginsburg/FabricOEEDemo.git
cd FabricOEEDemo
bash scripts/0-check-prereqs.sh
bash scripts/1-setup-fabric.sh --workspace-name "<FABRIC_WORKSPACE>"
```

Then connect the simulator and add the optional layers by following the
[setup guide](https://howardginsburg.github.io/FabricOEEDemo/setup/). The site's source is in [docs/](docs/).
