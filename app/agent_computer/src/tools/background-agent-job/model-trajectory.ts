import { z } from 'zod'

export const BackgroundAgentJobTrajectorySchema = z.object({
  format: z.literal('ankole_chatml'),
  version: z.literal(1),
  metadata: z
    .object({
      redacted: z.boolean().optional(),
      content_truncated: z.boolean().optional()
    })
    .optional(),
  messages: z.array(z.record(z.string(), z.unknown()))
})

export type BackgroundAgentJobTrajectory = z.output<typeof BackgroundAgentJobTrajectorySchema>

type Trajectory = {
  messages: Array<Record<string, unknown>>
}

/**
 * Removes stored protocol identities from a trajectory returned to the model.
 * Turn-local call aliases preserve the only useful relationship: which tool
 * result belongs to which tool call.
 */
export function modelVisibleTrajectory<T extends Trajectory>(trajectory: T): T {
  const calls = new Map<string, string>()

  const callAlias = (id: string): string => {
    const existing = calls.get(id)
    if (existing) return existing
    const alias = `call_${calls.size + 1}`
    calls.set(id, alias)
    return alias
  }

  const messages = trajectory.messages.map(message => {
    const { id: _messageID, ...projected } = message

    if (Array.isArray(projected.tool_calls)) {
      projected.tool_calls = projected.tool_calls.map(toolCall => {
        if (!isRecord(toolCall) || typeof toolCall.id !== 'string') return toolCall
        return { ...toolCall, id: callAlias(toolCall.id) }
      })
    }

    if (projected.role === 'tool' && typeof projected.tool_call_id === 'string') {
      projected.tool_call_id = callAlias(projected.tool_call_id)
    }

    return projected
  })

  return { ...trajectory, messages } as T
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
}
