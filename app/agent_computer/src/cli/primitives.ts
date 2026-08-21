import { z } from 'zod'

/** Human-facing label accepted by the turn-local shell CLIs. */
export const CLILabel = z.string().trim().min(1).max(500)

/** Parses one required positive-integer CLI option value. */
export function positiveInteger(value: string, name: string): number {
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${name} must be a positive integer`)
  return parsed
}
