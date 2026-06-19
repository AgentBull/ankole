import type { z } from 'zod'
import type { AgentTool } from '../core'

type AgentToolDefinition<TParameters extends z.ZodType, TDetails> = AgentTool<TParameters, TDetails>

/**
 * Fail-closed defaults for declarative tool behavior. A tool only declares what
 * it deviates from: omit `executionMode` and it runs sequentially; omit
 * `isReadOnly`/`isDestructive` and it's treated as a writing, potentially
 * destructive operation. The conservative stance is the default; tools opt into
 * the looser one explicitly.
 */
const TOOL_DEFAULTS = {
  executionMode: 'sequential',
  isReadOnly: false,
  isDestructive: true
} satisfies Partial<AgentTool>

/**
 * Build a complete `AgentTool` from a definition, filling in the fail-closed
 * defaults above. Keeps every tool's behavioral defaults in one place so the
 * runtime/permission layer reads declared behavior off a field instead of
 * scattered per-tool conditionals as the tool set grows.
 */
export function buildTool<TParameters extends z.ZodType, TDetails = unknown>(
  def: AgentToolDefinition<TParameters, TDetails>
): AgentTool<TParameters, TDetails> {
  return {
    ...TOOL_DEFAULTS,
    ...def
  }
}
