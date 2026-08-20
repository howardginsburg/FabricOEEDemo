/// Read surface for downtime FACTS. This calls the STANDALONE "Fabric API for GraphQL"
/// built over ManufacturingLH/dbo.RecentDowntime (see docs/DOWNTIME_LOGBOOK.md) — it is
/// separate from the Rayfin app's own GraphQL. The app never writes here; it only reads
/// the queue of downtime occurrences the operator annotates.

export interface DowntimeOccurrence {
  work_order_id: string;
  device_id: string;
  line_id: string;
  station_position: number;
  machine_type: string;
  issue_type: string;
  downtime_start: string; // ISO
}

const QUERY = `
query RecentDowntime {
  recentDowntimes(first: 200, orderBy: { downtime_start: DESC }) {
    items {
      work_order_id
      device_id
      line_id
      station_position
      machine_type
      issue_type
      downtime_start
    }
  }
}`;

/// Fetch recent downtime occurrences from the standalone GraphQL endpoint.
/// `accessToken` should be an Entra token authorized for that GraphQL API. In a
/// deployed Fabric SSO app the caller passes the current user's token; the endpoint
/// is configured for user (SSO passthrough) access. See docs/DOWNTIME_LOGBOOK.md.
export async function fetchRecentDowntime(accessToken?: string): Promise<DowntimeOccurrence[]> {
  const url = import.meta.env.VITE_RAYFIN_DOWNTIME_GRAPHQL_URL as string;
  if (!url || url.includes('<your-graphql-endpoint>')) {
    // Not configured yet — return empty so the UI renders without the read surface.
    return [];
  }
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {})
    },
    body: JSON.stringify({ query: QUERY })
  });
  if (!res.ok) {
    throw new Error(`RecentDowntime query failed: ${res.status} ${res.statusText}`);
  }
  const json = await res.json();
  return (json?.data?.recentDowntimes?.items ?? []) as DowntimeOccurrence[];
}

/// Stable key for an occurrence (device + start) used to diff against logged reasons.
export function occurrenceKey(device_id: string, downtime_start: string): string {
  return `${device_id}|${new Date(downtime_start).toISOString()}`;
}
