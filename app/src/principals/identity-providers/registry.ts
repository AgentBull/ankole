import type {
  BullXIdentityProviderAdapterFactory,
  BullXIdentityProviderAdapterFactoryContext
} from '@agentbull/bullx-sdk/plugins'

export type IdentityProviderAdapterFactory = BullXIdentityProviderAdapterFactory
export type IdentityProviderAdapterFactoryContext = BullXIdentityProviderAdapterFactoryContext

export class DuplicateIdentityProviderAdapterError extends Error {
  constructor(id: string) {
    super(`Identity provider adapter id is already registered: ${id}`)
    this.name = 'DuplicateIdentityProviderAdapterError'
  }
}

export class UnknownIdentityProviderAdapterError extends Error {
  constructor(id: string) {
    super(`Identity provider adapter is not registered: ${id}`)
    this.name = 'UnknownIdentityProviderAdapterError'
  }
}

/**
 * In-process registry of identity-provider adapter factories keyed by adapter id.
 *
 * This is the dependency-injection seam between plugin bootstrap (which registers
 * factories) and the runtime (which looks them up by the id named in activation
 * config). It is deliberately a plain map, not a database table: adapters are
 * code provided by loaded plugins, not persisted state.
 */
export class IdentityProviderAdapterRegistry {
  private readonly factories = new Map<string, IdentityProviderAdapterFactory>()

  /**
   * Registers a factory, rejecting a second factory that claims an id already
   * taken. Duplicate ids would make adapter resolution non-deterministic, so the
   * collision fails loud at startup instead of silently overwriting.
   */
  register(factory: IdentityProviderAdapterFactory): void {
    if (this.factories.has(factory.id)) throw new DuplicateIdentityProviderAdapterError(factory.id)
    this.factories.set(factory.id, factory)
  }

  get(id: string): IdentityProviderAdapterFactory {
    const factory = this.factories.get(id)
    if (!factory) throw new UnknownIdentityProviderAdapterError(id)

    return factory
  }

  listIds(): string[] {
    return [...this.factories.keys()]
  }
}

export function registerIdentityProviderAdapterFactory(factory: IdentityProviderAdapterFactory): void {
  identityProviderAdapterRegistry.register(factory)
}

export const identityProviderAdapterRegistry = new IdentityProviderAdapterRegistry()
