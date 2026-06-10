import type {
  BullXExternalGatewayAdapterFactory,
  BullXExternalGatewayAdapterFactoryContext
} from '@agentbull/bullx-sdk/plugins'

export type ExternalGatewayAdapterFactoryContext = BullXExternalGatewayAdapterFactoryContext
export type ExternalGatewayAdapterFactory = BullXExternalGatewayAdapterFactory

/**
 * Raised when an enabled channel asks for a factory that no plugin registered.
 *
 * This is a startup failure by design. Skipping the channel would leave the
 * service apparently healthy while external webhooks for that agent return 404.
 */
export class MissingExternalGatewayAdapterFactoryError extends Error {
  constructor(id: string) {
    super(`External Gateway adapter factory is not registered: ${id}`)
    this.name = 'MissingExternalGatewayAdapterFactoryError'
  }
}

/**
 * Raised when two built-in modules or enabled plugins try to own the same
 * External Gateway adapter factory id.
 */
export class DuplicateExternalGatewayAdapterFactoryError extends Error {
  constructor(id: string) {
    super(`External Gateway adapter factory is already registered: ${id}`)
    this.name = 'DuplicateExternalGatewayAdapterFactoryError'
  }
}

const factories = new Map<string, ExternalGatewayAdapterFactory>()

/**
 * Registers an External Gateway adapter factory by id. Plugin activation calls
 * this as a side effect of plugin loading; the runtime resolves by factory id.
 */
export function registerExternalGatewayAdapterFactory(factory: ExternalGatewayAdapterFactory): void {
  if (factories.has(factory.id)) throw new DuplicateExternalGatewayAdapterFactoryError(factory.id)

  factories.set(factory.id, factory)
}

/**
 * Resolves an adapter factory by metadata id.
 */
export function resolveExternalGatewayAdapterFactory(id: string): ExternalGatewayAdapterFactory {
  const factory = factories.get(id)
  if (!factory) throw new MissingExternalGatewayAdapterFactoryError(id)
  return factory
}
