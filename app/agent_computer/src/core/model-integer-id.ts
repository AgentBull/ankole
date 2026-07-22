import { z } from 'zod'

export const ModelIntegerID = z.number().int().min(1000).max(Number.MAX_SAFE_INTEGER)

export function modelIntegerIDFromWire(value: string, label: string): number {
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error(`${label} must be a canonical decimal integer`)
  const parsed = Number(value)
  const result = ModelIntegerID.safeParse(parsed)
  if (!result.success || String(result.data) !== value) {
    throw new Error(`${label} must be between 1000 and Number.MAX_SAFE_INTEGER`)
  }
  return result.data
}

export function modelIntegerIDToWire(value: number): string {
  return String(ModelIntegerID.parse(value))
}
