import type {
  BullXExternalGatewayAdapterFactory,
  BullXExternalGatewayAdapterFactoryContext
} from '@agentbull/bullx-sdk/plugins'
import { rootContainer } from '@/common/di'

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

/**
 * Registers an External Gateway adapter factory in the root tsyringe container.
 *
 * Keeping this in DI rather than a module-local map is deliberate: future plugin
 * activation will register factories as side effects of plugin loading, and the
 * runtime only needs to resolve by factory id.
 */
export function registerExternalGatewayAdapterFactory(factory: ExternalGatewayAdapterFactory): void {
  const token = externalGatewayAdapterFactoryToken(factory.id)
  if (rootContainer.isRegistered(token)) throw new DuplicateExternalGatewayAdapterFactoryError(factory.id)

  rootContainer.registerInstance(token, factory)
}

/**
 * Resolves an adapter factory by metadata id.
 */
export function resolveExternalGatewayAdapterFactory(id: string): ExternalGatewayAdapterFactory {
  try {
    return rootContainer.resolve<ExternalGatewayAdapterFactory>(externalGatewayAdapterFactoryToken(id))
  } catch (error) {
    throw new MissingExternalGatewayAdapterFactoryError(id)
  }
}

/**
 * Stable DI token namespace for External Gateway adapter factories.
 */
export function externalGatewayAdapterFactoryToken(id: string): string {
  return `external-gateway.adapter-factory.${id}`
}
