// @ts-nocheck
import type { JSONObject } from '@/llm/provider'
import type { InferToolInput, InferToolOutput, ToolSet } from '@/llm/provider-utils'
import type { ProviderMetadata } from '../types'
import type { ValueOf } from '../util/value-of'

export type StaticToolResult<TOOLS extends ToolSet> = ValueOf<{
  [NAME in keyof TOOLS]: {
    type: 'tool-result'
    toolCallId: string
    toolName: NAME & string
    input: InferToolInput<TOOLS[NAME]>
    output: InferToolOutput<TOOLS[NAME]>
    providerExecuted?: boolean
    providerMetadata?: ProviderMetadata
    toolMetadata?: JSONObject
    dynamic?: false | undefined
    preliminary?: boolean
    title?: string
  }
}>

export type DynamicToolResult = {
  type: 'tool-result'
  toolCallId: string
  toolName: string
  input: unknown
  output: unknown
  providerExecuted?: boolean
  providerMetadata?: ProviderMetadata
  toolMetadata?: JSONObject
  dynamic: true
  preliminary?: boolean
  title?: string
}

export type TypedToolResult<TOOLS extends ToolSet> = StaticToolResult<TOOLS> | DynamicToolResult
