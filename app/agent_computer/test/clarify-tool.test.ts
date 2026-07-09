import { describe, expect, it } from 'bun:test'
import { createClarifyTool } from '../src/tools/clarify/clarify-tool'
import { shouldNudgeEmptyAfterTools } from '../src/core/agent-loop'
import type { AssistantMessage } from '../src/core'

describe('@ankole/agent-computer clarify tool', () => {
  it('normalizes Hermes-style choice dictionaries and declares the turn-ending contract', async () => {
    const tool = createClarifyTool()
    const result = await tool.execute('clarify-1', {
      question: 'Who should this brief target?',
      choices: [
        { title: 'Operators', detail: 'People running the system.' },
        { description: 'Executives' },
        'Developers'
      ]
    })

    expect(result.details).toEqual({
      tool: 'clarify',
      ok: true,
      question: 'Who should this brief target?',
      choices: [
        { label: 'Operators', description: 'People running the system.' },
        { label: 'Executives' },
        { label: 'Developers' }
      ]
    })
    expect(result.content[0]).toMatchObject({ type: 'text' })
    expect(result.content[0]?.type === 'text' ? result.content[0].text : '').toContain('This turn ends here')
  })

  it('suppresses the empty-after-tools nudge after clarify', () => {
    const emptyStop = {
      role: 'assistant',
      content: [],
      stopReason: 'stop'
    } as AssistantMessage

    expect(shouldNudgeEmptyAfterTools(emptyStop, true, false, false)).toBe(true)
    expect(shouldNudgeEmptyAfterTools(emptyStop, true, false, true)).toBe(false)
  })
})
