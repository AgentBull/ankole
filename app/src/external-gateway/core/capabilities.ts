import { UnsupportedChannelCapabilityError } from './errors'

type CapabilityKind = 'inbound' | 'outbound'
type Capability = string

interface CapabilityCarrier {
  capabilities?: {
    inbound?: readonly string[]
    outbound?: readonly string[]
  }
  name: string
}

/**
 * Reports whether an adapter declares a given inbound/outbound capability.
 *
 * Capability negotiation is declaration-based: the runtime trusts the adapter's
 * declared list rather than probing for methods. An adapter that does not
 * declare a capability is treated as not having it, even if a matching method
 * happens to exist. Missing capability lists therefore mean "supports nothing".
 */
export function adapterSupportsCapability(
  adapter: CapabilityCarrier,
  kind: CapabilityKind,
  capability: Capability
): boolean {
  const declared = adapter.capabilities?.[kind] as readonly Capability[] | undefined
  return declared?.includes(capability) ?? false
}

/**
 * Returns an adapter's outbound method, but only when the capability is both
 * declared and actually implemented.
 *
 * This is the single gate the dispatcher uses before every outbound call. It
 * collapses two checks the caller would otherwise repeat — the declared
 * capability and the presence of the bound method — into one, and fails the
 * same way for both so the outbox can classify the result as `unsupported`
 * rather than a provider failure.
 *
 * @returns the method, narrowed to non-undefined, ready to call.
 * @throws UnsupportedChannelCapabilityError when the capability is undeclared or
 * the method is absent.
 */
export function requireOutboundCapability<TMethod extends Function>(
  adapter: CapabilityCarrier,
  capability: string,
  method: TMethod | undefined
): TMethod {
  if (!adapterSupportsCapability(adapter, 'outbound', capability) || typeof method !== 'function') {
    throw new UnsupportedChannelCapabilityError(adapter.name, capability)
  }

  return method
}
