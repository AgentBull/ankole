import { describe, expect, it } from 'bun:test'

import { buildAmbientRecognizerSystemPrompt, buildAmbientRecognizerUserPrompt } from '../src/prompts/ambient_prompt'

describe('@ankole/agent-computer ambient recognizer prompt', () => {
  it('keeps ambient intervention policy separate from the visible reply', () => {
    const systemPrompt = buildAmbientRecognizerSystemPrompt({
      agentUid: 'agent-1',
      channelLabel: 'Ops',
      conversationId: 'signal-channel:test',
      displayName: 'ReleaseBot',
      soul: 'Be useful.',
      timezone: 'Asia/Shanghai'
    })
    const userPrompt = buildAmbientRecognizerUserPrompt('current_observed_messages: []')

    expect(systemPrompt).toContain('This is an internal Ankole decision step, not the visible reply.')
    expect(systemPrompt).toContain('Use only the current observed messages as the trigger.')
    expect(systemPrompt).toContain('Use the structured output schema.')
    expect(userPrompt).toContain('<decision_input>')
    expect(userPrompt).toContain('current_observed_messages: []')
  })
})
