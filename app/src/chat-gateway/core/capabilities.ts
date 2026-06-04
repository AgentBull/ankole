import type {
  Adapter,
  ChannelHistoryCapability,
  ChannelInboundCapability,
  ChannelOutboundCapability
} from './types'
import { UnsupportedChannelCapabilityError } from './errors'

type CapabilityKind = 'history' | 'inbound' | 'outbound'
type Capability = ChannelHistoryCapability | ChannelInboundCapability | ChannelOutboundCapability

export function adapterSupportsCapability(
  adapter: Adapter,
  kind: 'history',
  capability: ChannelHistoryCapability
): boolean
export function adapterSupportsCapability(
  adapter: Adapter,
  kind: 'inbound',
  capability: ChannelInboundCapability
): boolean
export function adapterSupportsCapability(
  adapter: Adapter,
  kind: 'outbound',
  capability: ChannelOutboundCapability
): boolean
export function adapterSupportsCapability(adapter: Adapter, kind: CapabilityKind, capability: Capability): boolean {
  const declared = adapter.capabilities?.[kind] as readonly Capability[] | undefined
  return declared?.includes(capability) ?? false
}

export function requireOutboundCapability<TMethod extends Function>(
  adapter: Adapter,
  capability: ChannelOutboundCapability,
  method: TMethod | undefined
): TMethod {
  if (!adapterSupportsCapability(adapter, 'outbound', capability) || typeof method !== 'function') {
    throw new UnsupportedChannelCapabilityError(adapter.name, capability)
  }

  return method
}
