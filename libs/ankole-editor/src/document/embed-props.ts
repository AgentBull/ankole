/** Parameters supplied by one document embed to its Applet instance. */
export function parseEmbedProps(source: string | undefined): Record<string, unknown> {
  if (source === undefined) return {}
  if (new TextEncoder().encode(source).length > 16 * 1024) {
    throw new TypeError('Embed props must be a JSON object of at most 16 KiB')
  }
  const value: unknown = JSON.parse(source)
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError('Embed props must be a JSON object')
  }
  return value as Record<string, unknown>
}
