/** Returns the model-facing name for one SignalsGateway adapter. */
export function signalAdapterDisplayName(adapter: string | undefined): string | undefined {
  const value = adapter?.trim()
  if (!value) return undefined
  return value.toLowerCase() === 'lark' ? 'Lark / Feishu' : value
}
