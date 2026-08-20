import { RayfinClient } from '@microsoft/rayfin-client';
import type { DowntimeLogbookSchema } from '../rayfin/data/schema';

/// Rayfin client — used for the app's OWN data (DowntimeReason writes/reads) against
/// the app's managed Fabric SQL database via the app GraphQL. On the deployed app,
/// auth is Fabric SSO (Entra); locally it is email/password.
export const client = new RayfinClient<DowntimeLogbookSchema>({
  baseUrl: import.meta.env.VITE_RAYFIN_API_URL as string,
  publishableKey: import.meta.env.VITE_RAYFIN_PUBLISHABLE_KEY as string
});
