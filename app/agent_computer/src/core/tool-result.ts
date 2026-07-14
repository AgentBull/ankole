import type { AgentToolResult, ReplyPresentationEvent } from './types'

export interface JSONToolResultOptions {
  textPrefix?: string
  presentation?: ReplyPresentationEvent[]
  terminate?: boolean
}

export function jsonToolResult<TDetails>(
  details: TDetails,
  opts: JSONToolResultOptions = {}
): AgentToolResult<TDetails> {
  const text = JSON.stringify(details)
  return {
    content: [{ type: 'text', text: `${opts.textPrefix ?? ''}${text ?? 'undefined'}` }],
    details,
    ...(opts.presentation ? { presentation: opts.presentation } : {}),
    ...(opts.terminate ? { terminate: true } : {})
  }
}
