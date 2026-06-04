import type {
  BullXIdentityProviderAdapterFactory,
  BullXIdentityProviderAdapterFactoryContext
} from '@agentbull/bullx-sdk/plugins'
import { rootContainer, singleton } from '@/common/di'

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

@singleton()
export class IdentityProviderAdapterRegistry {
  private readonly factories = new Map<string, IdentityProviderAdapterFactory>()

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
  rootContainer.resolve(IdentityProviderAdapterRegistry).register(factory)
}

export const identityProviderAdapterRegistry = rootContainer.resolve(IdentityProviderAdapterRegistry)
