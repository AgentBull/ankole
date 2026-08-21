/**
 * Constructs a `WorkerAgentTool` from a zod-authored spec.
 *
 * Tool authors write zod, same as before this file existed. `defineWorkerTool`
 * derives the typebox view pi-agent-core's own validation gate needs
 * (`zodToTypeboxSchema`) and synthesizes the pi-required `label` from `name` —
 * neither is something a tool author should have to think about. The spec is
 * the tool: every other field passes through unchanged, so `WorkerAgentTool`
 * stays the single declaration of the authoring surface.
 */

import type { z } from 'zod'
import { Type } from 'typebox'
import { zodToTypeboxSchema } from './llm/tool-schema'
import type { WorkerAgentTool } from './types'

export type DefineWorkerToolSpec<TZod extends z.ZodType, TDetails> = Omit<
  WorkerAgentTool<TZod, TDetails>,
  'label' | 'parameters'
>

export function defineWorkerTool<TZod extends z.ZodType, TDetails = unknown>(
  spec: DefineWorkerToolSpec<TZod, TDetails>
): WorkerAgentTool<TZod, TDetails> {
  return {
    ...spec,
    label: spec.name,
    // Lazy: a tool that is constructed but never wired into a live turn (an
    // excluded/quarantined dynamic tool, a test fixture) must not pay for or
    // fail on schema derivation it never needed — `projection.ts` already
    // treats this same derivation as fallible and deferred; this matches it.
    get parameters() {
      return spec.jsonSchema ? Type.Unsafe(spec.jsonSchema) : zodToTypeboxSchema(spec.schema)
    }
  }
}
