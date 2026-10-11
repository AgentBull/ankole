import type { z } from 'zod'
import type { WorkerAgentTool } from './types'

export type DefineWorkerToolSpec<TZod extends z.ZodType, TDetails> = WorkerAgentTool<TZod, TDetails>

export function defineWorkerTool<TZod extends z.ZodType, TDetails = unknown>(
  spec: DefineWorkerToolSpec<TZod, TDetails>
): WorkerAgentTool<TZod, TDetails> {
  // Concurrent execution is only safe for a tool with no observable writes,
  // so the parallel mode is a structural claim, not a tuning knob.
  if (spec.executionMode === 'parallel' && (spec.isReadOnly !== true || spec.isDestructive === true)) {
    throw new Error(`parallel tool ${spec.name} must be read-only and not destructive`)
  }

  return spec
}
