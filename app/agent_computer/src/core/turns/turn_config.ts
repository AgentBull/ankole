import { ms } from '@pleisto/active-support'

// Hard cap for one text turn, not an inactivity budget. Tool-specific caps
// derive from this with a small margin.
export const TEXT_TURN_TIMEOUT_MS = positiveIntegerEnv('ANKOLE_TEXT_TURN_TIMEOUT_MS', ms('30m'))

/**
 * Reads a positive integer environment override or returns the fallback.
 */
function positiveIntegerEnv(name: string, fallback: number): number {
  const raw = process.env[name]
  if (!raw) return fallback

  const value = Number.parseInt(raw, 10)
  return Number.isFinite(value) && value > 0 ? value : fallback
}
