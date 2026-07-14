/** Case-insensitive client-side matching for the small operational resource lists. */
export function matchesResourceSearch(query: string, ...values: unknown[]): boolean {
  const needle = query.trim().toLocaleLowerCase()
  if (!needle) return true
  return values.some(value =>
    String(value ?? '')
      .toLocaleLowerCase()
      .includes(needle)
  )
}
