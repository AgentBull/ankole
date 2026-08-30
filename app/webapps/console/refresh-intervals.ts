/**
 * Refresh cadences for Console queries. One owner keeps the operator-facing
 * polling behavior reviewable in one place; pages pick the cadence that
 * matches what the user is watching.
 */

/** Standard cadence for operator list pages. */
export const LIST_REFRESH_MS = 15_000

/** Fast cadence for live job and run activity. */
export const ACTIVITY_REFRESH_MS = 5_000

/** Near-immediate cadence while a dialog or empty state waits for a change. */
export const WAITING_REFRESH_MS = 2_000

/** Relaxed cadence for slow-moving summaries. */
export const IDLE_REFRESH_MS = 30_000

/** Cadence for the worker registry once workers are present. */
export const SETTLED_WORKERS_REFRESH_MS = 10_000
