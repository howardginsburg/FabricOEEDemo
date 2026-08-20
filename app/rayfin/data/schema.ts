import type { DowntimeReason } from './DowntimeReason.js';

/// Entity map consumed by the Rayfin client for type-safe data access
/// (client.data.DowntimeReason.*).
export type DowntimeLogbookSchema = {
  DowntimeReason: DowntimeReason;
};
