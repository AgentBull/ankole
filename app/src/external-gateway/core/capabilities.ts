import { UnsupportedChannelCapabilityError } from './errors'

type CapabilityKind = 'history' | 'inbound' | 'outbound'
type Capability = string

interface CapabilityCarrier {
  capabilities?: {
    history?: readonly string[]
    inbound?: readonly string[]
    outbound?: readonly string[]
  }
  name: string
}

export function adapterSupportsCapability(
  adapter: CapabilityCarrier,
  kind: CapabilityKind,
  capability: Capability
): boolean {
  const declared = adapter.capabilities?.[kind] as readonly Capability[] | undefined
  return declared?.includes(capability) ?? false
}

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
