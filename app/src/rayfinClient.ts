import { RayfinClient } from '@microsoft/rayfin-client';
import type { FloorOpsSchema } from '../rayfin/data/schema';

/// Rayfin client — used for the app's OWN data (FloorEvent writes/reads) against the
/// app's managed Fabric SQL database via the app GraphQL. On the deployed app, auth is
/// Fabric SSO (Entra); locally it is email/password. The app both writes FloorEvents and
/// reads them back for the in-app Insights dashboard — all against its own managed DB, so
/// no external data source and no separate Entra app registration is required.
export const client = new RayfinClient<FloorOpsSchema>({
  baseUrl: import.meta.env.VITE_RAYFIN_API_URL as string,
  publishableKey: import.meta.env.VITE_RAYFIN_PUBLISHABLE_KEY as string
});

/// Fabric brokered-auth (SSO) options, sourced from the VITE_FABRIC_* values that
/// `rayfin up` emits into .env.local. Used by @microsoft/rayfin-auth-provider-fabric
/// to obtain a Rayfin session — automatically when the app is launched embedded in
/// the Fabric portal (postMessage handoff), or via a popup for standalone access.
export const fabricAuthOptions = {
  workspaceId: import.meta.env.VITE_FABRIC_WORKSPACE_ID as string,
  projectId: import.meta.env.VITE_FABRIC_ITEM_ID as string,
  fabricPortalUrl: import.meta.env.VITE_FABRIC_PORTAL_URL as string,
  returnOrigin: window.location.origin
};
