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
import type { WorkerAgentTool } from './types'

export type DefineWorkerToolSpec<TZod extends z.ZodType, TDetails> = Omit<
  WorkerAgentTool<TZod, TDetails>,
  'label' | 'parameters'
>

const PERMISSIVE_PI_PARAMETERS = Type.Any()

export function defineWorkerTool<TZod extends z.ZodType, TDetails = unknown>(
  spec: DefineWorkerToolSpec<TZod, TDetails>
): WorkerAgentTool<TZod, TDetails> {
  return {
    ...spec,
    label: spec.name,
    parameters: PERMISSIVE_PI_PARAMETERS
  }
}
