import type { z } from 'zod'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
export type CustomToolInputFormat = { type: 'text' } | { type: 'grammar'; syntax: 'lark' | 'regex'; definition: string }
export type TextContent = { type: 'text'; text: string }
export type ImageContent = { type: 'image'; image: string | URL | Uint8Array | BufferSource; mimeType?: string }
export type ContentPart = TextContent | ImageContent
export type AgentLoopLogger = {
  info(event: string, message: string, fields?: JSONObject): void
  warning(event: string, message: string, fields?: JSONObject): void
}
export interface AgentToolResult<T> {
  content: ContentPart[]
  details: T
  isError?: boolean
  failureKind?: string
}
export interface WorkerAgentTool<TZod extends z.ZodType = z.ZodType, TDetails = any> {
  name: string
  description: string
  executionMode: 'parallel' | 'sequential'
  /** Validates environment tool input before execution. */
  schema: TZod
  /** Declares a Responses custom tool whose model input is raw text. */
  inputFormat?: CustomToolInputFormat
  isReadOnly?: boolean
  isDestructive?: boolean
  /** Re-execution is safe if the Worker process lost the earlier result. */
  retrySafe?: boolean
  /** Builds one bounded user-facing activity label from schema-validated parameters. */
  describeActivity: (params: z.output<TZod>) => ActivityDescription | string | null
  /** Optionally replaces the activity label with a bounded summary of the completed result. */
  describeCompletedActivity?: (params: z.output<TZod>, details: TDetails) => ActivityDescription | string | null
  /** The workspace records a failed execution as a tool result. */
  execute: (toolCallID: string, params: z.output<TZod>, signal?: AbortSignal) => Promise<AgentToolResult<TDetails>>
}

export type ActivityDescription = {
  key: string
  bindings?: JSONObject
}
