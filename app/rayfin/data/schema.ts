import type { FloorEvent } from './FloorEvent.js';

/// Entity map consumed by the Rayfin client for type-safe data access
/// (client.data.FloorEvent.*). The app owns and writes FloorEvent to its managed
/// Fabric SQL database, and reads its own rows back for the in-app Insights dashboard.
export type FloorOpsSchema = {
  FloorEvent: FloorEvent;
};
