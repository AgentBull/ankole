export type AppletCode = { source: string; env: Record<string, string> }

export class CodeCache {
  private entries = new Map<string, { code: AppletCode; bytes: number }>()
  private bytes = 0

  constructor(private readonly maxBytes = 256 * 1024 * 1024) {}

  get(key: string) {
    const entry = this.entries.get(key)
    if (!entry) return undefined
    this.entries.delete(key)
    this.entries.set(key, entry)
    return entry.code
  }

  put(key: string, code: AppletCode) {
    const bytes = new TextEncoder().encode(JSON.stringify(code)).length
    if (bytes > this.maxBytes) throw new RangeError('Applet code exceeds the cache limit')
    const existing = this.entries.get(key)
    if (existing) this.bytes -= existing.bytes
    this.entries.delete(key)
    while (this.bytes + bytes > this.maxBytes) {
      const oldest = this.entries.keys().next().value!
      this.bytes -= this.entries.get(oldest)!.bytes
      this.entries.delete(oldest)
    }
    this.entries.set(key, { code, bytes })
    this.bytes += bytes
  }
}
