import { describe, expect, it } from 'bun:test'
import type { WebProvider, WebProviderKind } from './provider'
import { WebProviderRegistry } from './registry'

// Minimal stub provider. Mirrors the real contract by wiring search/extract only
// for the kinds listed in `supports`, so tests exercise the same capability check
// the registry runs.
function fakeProvider(
  id: string,
  supports: WebProviderKind[],
  options: { available?: boolean; unavailableReason?: string } = {}
): WebProvider {
  return {
    id,
    supports,
    available: () => options.available ?? true,
    unavailableReason: () => options.unavailableReason,
    search: supports.includes('search') ? async () => [{ title: id, url: 'https://u', snippet: 's' }] : undefined,
    extract: supports.includes('extract') ? async () => [{ url: 'https://u', title: id, text: 't' }] : undefined
  }
}

describe('WebProviderRegistry.select', () => {
  // Walks the full selection ladder in one test: each `clear()` resets to a fresh
  // scenario that isolates one rung — explicit preferred, built-in priority order,
  // skipping an unavailable built-in, and finally a plugin-only provider.
  it('uses preferred provider first, built-in priority next, and plugin providers as last resort', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('exa', ['search']))
    registry.register(fakeProvider('grok', ['search']))
    expect((await registry.select('search', 'grok')).id).toBe('grok')

    expect((await registry.select('search')).id).toBe('exa')

    registry.clear()
    registry.register(fakeProvider('exa', ['search'], { available: false }))
    registry.register(fakeProvider('parallel', ['search']))
    expect((await registry.select('search')).id).toBe('parallel')

    registry.clear()
    registry.register(fakeProvider('custom', ['search']))
    expect((await registry.select('search')).id).toBe('custom')
  })

  it('throws when no provider is available', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('exa', ['search'], { available: false }))
    await expect(registry.select('search')).rejects.toThrow()
  })

  // Pins the core policy difference: an explicitly configured-but-unavailable
  // provider raises (carrying its `unavailableReason`) even though another
  // available provider (parallel) is registered and would satisfy a fallback.
  it('fails fast for explicitly configured providers instead of falling back', async () => {
    const registry = new WebProviderRegistry()
    registry.register(
      fakeProvider('exa', ['search'], { available: false, unavailableReason: 'exa api key not configured' })
    )
    registry.register(fakeProvider('parallel', ['search']))

    await expect(registry.select('search', 'exa')).rejects.toThrow(
      'configured search provider is unavailable: exa (exa api key not configured)'
    )
  })

  it('reports explicit provider registration and capability errors precisely', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('jina', ['extract']))

    await expect(registry.select('search', 'missing')).rejects.toThrow(
      'configured search provider is not registered: missing'
    )
    await expect(registry.select('search', 'jina')).rejects.toThrow(
      'configured search provider does not support search: jina'
    )
  })
})

describe('WebProviderRegistry.register', () => {
  it('throws on a duplicate id', () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('exa', ['search']))
    expect(() => registry.register(fakeProvider('exa', ['extract']))).toThrow()
  })
})

describe('WebProviderRegistry.hasAnyAvailable', () => {
  it('reflects availability per capability', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('jina', ['extract']))
    expect(await registry.hasAnyAvailable('extract')).toBe(true)
    expect(await registry.hasAnyAvailable('search')).toBe(false)
  })
})
