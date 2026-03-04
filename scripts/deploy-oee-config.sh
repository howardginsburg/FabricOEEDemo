# =============================================================================
# deploy-oee-config.sh — Configuration for deploy-oee-assets.sh and
#                         promote-discovered-assets.sh
#
# Edit these values to match your environment, then run deploy-oee-assets.sh.
# =============================================================================

# ── Azure IoT Operations (required) ──────────────────────────────────────────
INSTANCE=""                # AIO instance name
RESOURCE_GROUP=""          # Resource group containing the AIO instance

# ── Fabric Real-Time Intelligence (optional) ──────────────────────────────────
# Provide the workspace name, EventHub host, and EventHub topic to create a
# dataflow using the AIO extension's managed identity (Entra ID).
# Leave WORKSPACE_NAME empty to skip dataflow creation.
# Get host and topic from: Eventstream → custom endpoint source → Entra ID Authentication tab
WORKSPACE_NAME=""          # Fabric workspace name (leave empty to skip dataflow)
EVENTHUB_NAMESPACE=""      # EventHub namespace, e.g. xxxx.servicebus.windows.net (port 9093 is added automatically)
EVENTHUB_NAME=""           # EventHub name, e.g. es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb
