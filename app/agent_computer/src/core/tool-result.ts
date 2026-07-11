import type { AgentToolResult } from './types'

export interface JSONToolResultOptions {
  textPrefix?: string
}

export function jsonToolResult<TDetails>(
  details: TDetails,
  opts: JSONToolResultOptions = {}
): AgentToolResult<TDetails> {
  const text = JSON.stringify(details)
  return {
    content: [{ type: 'text', text: `${opts.textPrefix ?? ''}${text ?? 'undefined'}` }],
    details
  }
}
