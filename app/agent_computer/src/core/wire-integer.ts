export function nonNegativeSafeIntegerFromWire(value: string, field: string): number {
  if (!/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`${field} is not a non-negative integer`)
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed)) throw new Error(`${field} exceeds the model integer range`)
  return parsed
}
