import type { AgentToolResult } from './types'

export function jsonToolResult<TDetails>(details: TDetails): AgentToolResult<TDetails> {
  return {
    content: [{ type: 'text', text: JSON.stringify(details) ?? 'undefined' }],
    details
  }
}
