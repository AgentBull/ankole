export function unusedProviderID(defaultID: string, existingIDs: readonly string[]): string {
  const existing = new Set(existingIDs)
  let candidate = defaultID
  for (let suffix = 2; existing.has(candidate); suffix++) candidate = `${defaultID}-${suffix}`
  return candidate
}
