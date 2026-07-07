import type { AgentToolResult } from './types'

export interface JsonToolResultOptions {
  textPrefix?: string
}

export function jsonToolResult<TDetails>(
  details: TDetails,
  opts: JsonToolResultOptions = {}
): AgentToolResult<TDetails> {
  const text = JSON.stringify(details)
  return {
    content: [{ type: 'text', text: `${opts.textPrefix ?? ''}${text ?? 'undefined'}` }],
    details
  }
}
