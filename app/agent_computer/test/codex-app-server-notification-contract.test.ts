import { describe, expect, it } from 'bun:test'
import { CODEX_OPT_OUT_NOTIFICATION_METHODS } from '../src/core/codex-runner/runtime/app-server-client'

describe('@ankole/agent-computer Codex app-server notification contract', () => {
  it('keeps the exact delta opt-out contract', () => {
    expect(CODEX_OPT_OUT_NOTIFICATION_METHODS).toEqual([
      'item/agentMessage/delta',
      'item/plan/delta',
      'item/reasoning/summaryPartAdded',
      'item/reasoning/summaryTextDelta',
      'item/reasoning/textDelta',
      'item/commandExecution/outputDelta',
      'item/commandExecution/terminalInteraction',
      'item/fileChange/outputDelta',
      'item/fileChange/patchUpdated',
      'item/mcpToolCall/progress'
    ])
  })
})
