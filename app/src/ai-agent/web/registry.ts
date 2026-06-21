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

  /**
   * Whether the provider can actually serve `kind`: it must both advertise the
   * capability AND implement the matching method. The method check guards a
   * provider that lists a kind in `supports` but never wired up the function.
   */
  private supportsKind(provider: WebProvider, kind: WebProviderKind): boolean {
    if (!provider.supports.includes(kind)) return false
    return kind === 'search' ? typeof provider.search === 'function' : typeof provider.extract === 'function'
  }

  /**
   * Returns the provider only if it exists, can serve `kind`, and reports itself
   * available right now; otherwise `undefined`. Used by fallback selection, where a
   * provider that fails any of these is simply skipped rather than raising.
   */
  private async usable(provider: WebProvider | undefined, kind: WebProviderKind): Promise<WebProvider | undefined> {
    if (!provider || !this.supportsKind(provider, kind)) return undefined
    return (await provider.available(kind)) ? provider : undefined
  }

  /**
   * Resolves an operator-pinned provider, or raises. This is the deliberate
   * counterpart to fallback selection: once an operator names a provider, an
   * unexpected fallback to a different one would be surprising and could leak
   * queries to an unintended vendor, so any of the three failure modes — not
   * registered, wrong capability, configured-but-unavailable — fails fast with a
   * precise, non-retryable error instead of silently substituting another.
   */
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
    // Last resort: any registered provider not already tried above (i.e. plugin
    // providers). Built-ins are skipped here because the priority loop just
    // covered them — re-checking would only repeat their availability calls.
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
