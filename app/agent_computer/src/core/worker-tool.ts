/**
 * Constructs a `WorkerAgentTool` from a zod-authored spec.
 *
 * Tool authors write zod, same as before this file existed. `defineWorkerTool`
 * derives the typebox view pi-agent-core's own validation gate needs
 * (`zodToTypeboxSchema`) and synthesizes the pi-required `label` from `name` —
 * neither is something a tool author should have to think about.
 */

import type { z } from 'zod'
import type { AgentToolUpdateCallback } from '@earendil-works/pi-agent-core'
import type { CustomToolInputFormat } from 'openai/resources/shared'
import { Type } from 'typebox'
import { zodToTypeboxSchema } from './llm/tool-schema'
import type { ActivityDescription, AgentToolExecutionMode, AgentToolResult, WorkerAgentTool } from './types'

export interface DefineWorkerToolSpec<TZod extends z.ZodType, TDetails> {
  name: string
  description: string
  schema: TZod
  /** Declares a Responses custom tool whose model input is raw text. */
  inputFormat?: CustomToolInputFormat
  /** Optional raw JSON Schema used when a tool comes from an external catalog. */
  jsonSchema?: Record<string, unknown>
  /** Optional result schema from the tool owner. */
  outputSchema?: Record<string, unknown>
  /** Groups this tool under one Responses namespace. */
  namespace?: string
  namespaceDescription?: string
  /** Hides the schema until Tool Search loads this tool. */
  deferLoading?: boolean
  /** Search corpus supplied by the owning external catalog. */
  toolSearchText?: string
  /** Responses callers that may invoke this tool. */
  allowedCallers?: Array<'direct' | 'programmatic'>
  executionMode?: AgentToolExecutionMode
  isReadOnly?: boolean
  isDestructive?: boolean
  /** Builds one bounded user-facing activity label from schema-validated parameters. */
  describeActivity: (params: z.output<TZod>) => ActivityDescription | string | null
  /** Optionally replaces the activity label with a bounded summary of the completed result. */
  describeCompletedActivity?: (params: z.output<TZod>, details: TDetails) => ActivityDescription | string | null
  /** Throw on failure instead of encoding errors in `content` — pi's own tool-loop catches it. */
  execute: (
    toolCallID: string,
    params: z.output<TZod>,
    signal?: AbortSignal,
    onUpdate?: AgentToolUpdateCallback<TDetails>
  ) => Promise<AgentToolResult<TDetails>>
}

export function defineWorkerTool<TZod extends z.ZodType, TDetails = unknown>(
  spec: DefineWorkerToolSpec<TZod, TDetails>
): WorkerAgentTool<TZod, TDetails> {
  return {
    name: spec.name,
    label: spec.name,
    description: spec.description,
    schema: spec.schema,
    // Lazy: a tool that is constructed but never wired into a live turn (an
    // excluded/quarantined dynamic tool, a test fixture) must not pay for or
    // fail on schema derivation it never needed — `projection.ts` already
    // treats this same derivation as fallible and deferred; this matches it.
    get parameters() {
      return spec.jsonSchema ? Type.Unsafe(spec.jsonSchema) : zodToTypeboxSchema(spec.schema)
    },
    inputFormat: spec.inputFormat,
    jsonSchema: spec.jsonSchema,
    outputSchema: spec.outputSchema,
    namespace: spec.namespace,
    namespaceDescription: spec.namespaceDescription,
    deferLoading: spec.deferLoading,
    toolSearchText: spec.toolSearchText,
    allowedCallers: spec.allowedCallers,
    executionMode: spec.executionMode,
    isReadOnly: spec.isReadOnly,
    isDestructive: spec.isDestructive,
    describeActivity: spec.describeActivity,
    describeCompletedActivity: spec.describeCompletedActivity,
    execute: spec.execute
  }
}
