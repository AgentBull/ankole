import type { Adapter } from 'chat'

export type BullXPluginJsonValue =
  | string
  | number
  | boolean
  | null
  | { [key: string]: BullXPluginJsonValue }
  | BullXPluginJsonValue[]

export interface BullXPluginJsonSchema<TValue extends BullXPluginJsonValue = BullXPluginJsonValue> {
  parse(value: unknown): TValue
}

export interface BullXAppConfigDefinition<TValue extends BullXPluginJsonValue = BullXPluginJsonValue> {
  key: string
  schema: BullXPluginJsonSchema<TValue>
  encrypted: boolean
  defaultValue?: TValue
  description?: string
}

export interface BullXAppConfigPatternDefinition<TValue extends BullXPluginJsonValue = BullXPluginJsonValue> {
  id: string
  keyPattern: RegExp
  schema: BullXPluginJsonSchema<TValue>
  encrypted: boolean
  defaultValue?: TValue
  description?: string
}

export interface BullXAgentChannelBinding {
  adapter: string
  enabled: boolean
  name: string
}

export interface BullXChatGatewayAdapterFactoryContext {
  agent: unknown
  channel: BullXAgentChannelBinding
  config: BullXPluginJsonValue | undefined
  projection: unknown
}

export interface BullXChatGatewayAdapterFactory {
  id: string
  create(context: BullXChatGatewayAdapterFactoryContext): Adapter | Promise<Adapter>
}

export interface BullXPluginMetadata {
  id: string
  apiVersion: 1
  displayName?: string
  description?: string
}

export interface BullXPlugin {
  metadata: BullXPluginMetadata
  appConfigDefinitions?: readonly BullXAppConfigDefinition[]
  appConfigPatterns?: readonly BullXAppConfigPatternDefinition[]
  chatGatewayAdapters?: readonly BullXChatGatewayAdapterFactory[]
}

export function defineBullXPlugin<const TPlugin extends BullXPlugin>(plugin: TPlugin): TPlugin {
  return plugin
}
