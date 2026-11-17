export type AppletBindings = Record<
  string,
  {
    tableId: string | null
    fields: Record<string, string | null>
    status: 'ready' | 'missing_table' | 'missing_fields'
    missing: string[]
    required: boolean
    description: string | null
  }
>
export type AppletCode = { source: string; env: Record<string, string>; bindings?: AppletBindings }

const ordered = <T>(entries: [string, T][]) =>
  entries.sort(([a], [b]) => {
    const left = Array.from(a, char => char.codePointAt(0)!)
    const right = Array.from(b, char => char.codePointAt(0)!)
    for (let index = 0; index < Math.min(left.length, right.length); index++) {
      if (left[index] !== right[index]) return left[index] - right[index]
    }
    return left.length - right.length
  })
async function digest(value: string) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, '0')).join('')
}
export function appletBindingsDigest(bindings: AppletBindings = {}) {
  return digest(
    JSON.stringify(
      ordered(Object.entries(bindings)).map(([slot, binding]) => [
        slot,
        [binding.tableId, ordered(Object.entries(binding.fields))]
      ])
    )
  )
}
export async function appletCodeDigest(code: AppletCode) {
  return digest(
    `${code.source}\n${JSON.stringify(ordered(Object.entries(code.env)))}\n${await appletBindingsDigest(code.bindings)}`
  )
}

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
