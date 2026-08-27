/**
 * Constructs a `WorkerAgentTool` from a zod-authored spec.
 *
 * Tool authors write zod, same as before this file existed. `defineWorkerTool`
 * synthesizes the pi-required `label` from `name` and fills `parameters` —
 * consumed only by pi-agent-core's own pre-`execute()` gate — with an
 * always-passing schema. pi would otherwise reject arguments before
 * `beforeToolCall` runs, with its own message that names pi's registered
 * (identity-aliased) tool name; the loop's strict zod gate in `agent-loop.ts`
 * is the single owner of argument validation and speaks wire names and the
 * worker failure format. The model-visible JSON Schema derives from `schema`
 * (or `jsonSchema`) in `wire.ts`, never from `parameters`. The spec is the
 * tool: every other field passes through unchanged, so `WorkerAgentTool`
 * stays the single declaration of the authoring surface.
 */

import type { z } from 'zod'
import { Type } from 'typebox'
import type { ToolExecutionMode } from '@earendil-works/pi-agent-core'
import type { WorkerAgentTool } from './types'

export type DefineWorkerToolSpec<TZod extends z.ZodType, TDetails> = Omit<
  WorkerAgentTool<TZod, TDetails>,
  'label' | 'parameters'
> & {
  /**
   * Required here although pi's own field is optional: pi treats an
   * undeclared mode as parallel-capable, so an omission would widen a tool's
   * concurrency silently instead of failing the author.
   */
  executionMode: ToolExecutionMode
}

const PERMISSIVE_PI_PARAMETERS = Type.Any()

export function defineWorkerTool<TZod extends z.ZodType, TDetails = unknown>(
  spec: DefineWorkerToolSpec<TZod, TDetails>
): WorkerAgentTool<TZod, TDetails> {
  // Concurrent execution is only safe for a tool with no observable writes,
  // so the parallel mode is a structural claim, not a tuning knob.
  if (spec.executionMode === 'parallel' && (spec.isReadOnly !== true || spec.isDestructive === true)) {
    throw new Error(`parallel tool ${spec.name} must be read-only and not destructive`)
  }

  return {
    ...spec,
    label: spec.name,
    parameters: PERMISSIVE_PI_PARAMETERS
  }
}
