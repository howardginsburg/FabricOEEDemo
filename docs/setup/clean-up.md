# Clean up

## Between demos

The live pipeline is light, but the agents and the capacity itself cost money while they run. After each demo:

1. **Stop the operations agent.**

    ```bash
    python3 scripts/11-setup-operations-agent.py --workspace-name "<FABRIC_WORKSPACE>" --stop
    ```

2. **Stop the simulator.** Select **Stop**, then close the window.
3. **Close the ontology** if it's open in the portal. An open ontology re-reads its definition about every 20
   minutes.
4. **Pause the capacity.** In the [Azure portal](https://portal.azure.com), open the Fabric capacity and select
   **Pause**. Select **Resume** before the next demo, then check the Eventstream's destinations
   ([step 1](fabric-foundation.md#check-the-eventstream)). From the CLI:

    ```bash
    CAP_ID=$(az resource show --resource-group <CAPACITY_RESOURCE_GROUP> --name <CAPACITY_NAME> \
      --resource-type Microsoft.Fabric/capacities --query id -o tsv)
    az rest --method post --url "https://management.azure.com$CAP_ID/suspend?api-version=2023-11-01"
    az rest --method post --url "https://management.azure.com$CAP_ID/resume?api-version=2023-11-01"
    ```

!!! note
    Pausing a capacity bills its remaining smoothed usage at once; see
    [Capacity and cost](../reference/capacity.md). In Azure, the AI Search service bills by the hour while it
    exists, and the model deployments bill only for the tokens they use.

## Remove the demo

1. **Delete the Fabric workspace.** Open the workspace, select **Workspace settings** > **General** >
   **Remove this workspace**. This deletes every item in it, including the Floor Ops Console and its database.
2. **Delete the Azure resource group** from steps 9 and 10:

    ```bash
    az group delete --name <RESOURCE_GROUP>
    ```

3. **Purge the Foundry resource**, if you want to reuse its name. A deleted Foundry resource is kept in a
   soft-deleted state for 48 hours:

    ```bash
    az cognitiveservices account purge --name <FOUNDRY_RESOURCE_NAME> \
      --resource-group <RESOURCE_GROUP> --location <AZURE_REGION>
    ```

4. **Delete the local files that hold keys and ids:** `simulator/FabricOEESimulator.Wpf/simulator.local.yaml`,
   `app/rayfin/.env`, and `app/.env.local`.

If you created the Fabric capacity only for this demo, delete it in the Azure portal too.
