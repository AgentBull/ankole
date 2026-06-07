import { describe, expect, it } from 'bun:test'
import type { WebProvider, WebProviderKind } from './provider'
import { WebProviderRegistry } from './registry'

function fakeProvider(
  id: string,
  supports: WebProviderKind[],
  options: { available?: boolean } = {}
): WebProvider {
  return {
    id,
    supports,
    available: () => options.available ?? true,
    search: supports.includes('search') ? async () => [{ title: id, url: 'https://u', snippet: 's' }] : undefined,
    extract: supports.includes('extract') ? async () => [{ url: 'https://u', title: id, text: 't' }] : undefined
  }
}

describe('WebProviderRegistry.select', () => {
  it('prefers the configured provider when available', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('exa', ['search']))
    registry.register(fakeProvider('grok', ['search']))
    expect((await registry.select('search', 'grok')).id).toBe('grok')
  })

  it('falls back to built-in priority order', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('grok', ['search']))
    registry.register(fakeProvider('exa', ['search']))
    expect((await registry.select('search')).id).toBe('exa')
  })

  it('skips unavailable providers', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('exa', ['search'], { available: false }))
    registry.register(fakeProvider('parallel', ['search']))
    expect((await registry.select('search')).id).toBe('parallel')
  })

  it('selects a non-built-in (plugin) provider as a last resort', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('custom', ['search']))
    expect((await registry.select('search')).id).toBe('custom')
  })

  it('throws when no provider is available', async () => {
    const registry = new WebProviderRegistry()
    registry.register(fakeProvider('exa', ['search'], { available: false }))
    await expect(registry.select('search')).rejects.toThrow()
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
