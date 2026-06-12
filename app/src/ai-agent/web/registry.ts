import type { WebProvider, WebProviderKind } from './provider'
import { WebProviderError } from './provider'

/**
 * Built-in selection order per capability. Plugin-contributed providers are not
 * listed here; they are selected either via an explicit preferred id, or as a
 * last-resort fallback after all built-ins (so a plugin-only provider still
 * makes the tool work and keeps `select`/`hasAnyAvailable` consistent).
 */
const BUILTIN_PRIORITY: Record<WebProviderKind, readonly string[]> = {
  search: ['exa', 'parallel'],
  extract: ['exa', 'jina', 'webfetch']
}

export class WebProviderRegistry {
  private readonly providers = new Map<string, WebProvider>()

  /** Register a provider. Throws on duplicate id (startup-fail on collision). */
  register(provider: WebProvider): void {
    if (this.providers.has(provider.id)) {
      throw new Error(`Duplicate web provider id: ${provider.id}`)
    }
    this.providers.set(provider.id, provider)
  }

  get(id: string): WebProvider | undefined {
    return this.providers.get(id)
  }

  list(): WebProvider[] {
    return [...this.providers.values()]
  }

  private supportsKind(provider: WebProvider, kind: WebProviderKind): boolean {
    if (!provider.supports.includes(kind)) return false
    return kind === 'search' ? typeof provider.search === 'function' : typeof provider.extract === 'function'
  }

  private async usable(provider: WebProvider | undefined, kind: WebProviderKind): Promise<WebProvider | undefined> {
    if (!provider || !this.supportsKind(provider, kind)) return undefined
    return (await provider.available(kind)) ? provider : undefined
  }

  private async requirePreferred(kind: WebProviderKind, preferredId: string): Promise<WebProvider> {
    const provider = this.providers.get(preferredId)
    if (!provider) {
      throw new WebProviderError(`configured ${kind} provider is not registered: ${preferredId}`, {
        retryable: false,
        providerId: preferredId
      })
    }
    if (!this.supportsKind(provider, kind)) {
      throw new WebProviderError(`configured ${kind} provider does not support ${kind}: ${preferredId}`, {
        retryable: false,
        providerId: preferredId
      })
    }
    if (await provider.available(kind)) return provider
    const reason = (await provider.unavailableReason?.(kind)) ?? 'provider is unavailable'
    throw new WebProviderError(`configured ${kind} provider is unavailable: ${preferredId} (${reason})`, {
      retryable: false,
      providerId: preferredId
    })
  }

  /**
   * Resolve a provider for `kind`:
   *   1. configured `preferredId`, failing fast if registered capability/config is invalid
   *   2. first built-in (priority order) that is registered + available
   *   3. any remaining registered (e.g. plugin) provider that is available
   * Throws `WebProviderError` when none is available.
   */
  async select(kind: WebProviderKind, preferredId?: string): Promise<WebProvider> {
    if (preferredId) {
      return this.requirePreferred(kind, preferredId)
    }
    for (const id of BUILTIN_PRIORITY[kind]) {
      const builtin = await this.usable(this.providers.get(id), kind)
      if (builtin) return builtin
    }
    const builtinIds = new Set(BUILTIN_PRIORITY[kind])
    for (const provider of this.providers.values()) {
      if (builtinIds.has(provider.id)) continue
      const extra = await this.usable(provider, kind)
      if (extra) return extra
    }
    throw new WebProviderError(`no available ${kind} provider`, { retryable: false, providerId: '' })
  }

  /** True if at least one registered provider is available for `kind`. */
  async hasAnyAvailable(kind: WebProviderKind): Promise<boolean> {
    for (const provider of this.providers.values()) {
      if (await this.usable(provider, kind)) return true
    }
    return false
  }

  /** Test helper: drop all registrations. */
  clear(): void {
    this.providers.clear()
  }
}

export const webProviderRegistry = new WebProviderRegistry()
