/** Clears a resource filter immediately while non-empty queries can remain deferred. */
export function effectiveResourceSearchQuery(query: string, deferredQuery: string): string {
  return query.trim() ? deferredQuery : ''
}

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
