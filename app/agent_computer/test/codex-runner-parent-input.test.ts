import { describe, expect, it } from 'bun:test'
import type { DynamicToolCallParams } from '../src/core/codex-runner/generated/protocol/v2/DynamicToolCallParams'
import {
  pendingParentInputFromDynamicTool,
  PARENT_INPUT_TOOL_NAME,
  parentInputToolSpec
} from '../src/core/codex-runner/parent-input'

describe('@ankole/agent-computer BackgroundAgentJob parent-input bridge', () => {
  it('publishes a bounded concrete tool contract for Default-mode background execution', () => {
    const spec = parentInputToolSpec()

    expect(spec).toMatchObject({
      type: 'function',
      name: PARENT_INPUT_TOOL_NAME
    })
    if (spec.type !== 'function') throw new Error('parent-input bridge must be a function tool')
    expect(spec.inputSchema).toMatchObject({
      type: 'object',
      required: ['questions'],
      additionalProperties: false,
      properties: {
        questions: expect.objectContaining({ minItems: 1, maxItems: 3 })
      }
    })
  })

  it('normalizes a valid lead request to the official pending-user-input shape', () => {
    expect(
      pendingParentInputFromDynamicTool(
        call({
          questions: [
            {
              id: 'audience',
              header: 'Audience',
              question: 'Who should receive the report?',
              options: [{ label: 'Operators', description: 'The operations team.' }]
            }
          ]
        })
      )
    ).toEqual({
      threadId: 'thread-lead',
      turnId: 'turn-lead',
      itemId: 'call-parent-input',
      autoResolutionMs: null,
      questions: [
        {
          id: 'audience',
          header: 'Audience',
          question: 'Who should receive the report?',
          isOther: true,
          isSecret: false,
          options: [{ label: 'Operators', description: 'The operations team.' }]
        }
      ]
    })
  })

  it('rejects malformed, oversized, and unrelated calls instead of pausing the Job', () => {
    expect(pendingParentInputFromDynamicTool(call({ questions: [] }))).toBeUndefined()
    expect(
      pendingParentInputFromDynamicTool(
        call({
          questions: Array.from({ length: 4 }, (_value, index) => ({
            id: `question-${index}`,
            header: 'Question',
            question: 'Choose one.'
          }))
        })
      )
    ).toBeUndefined()
    expect(pendingParentInputFromDynamicTool({ ...call({ questions: [] }), tool: 'another_tool' })).toBeUndefined()
  })
})

function call(argumentsValue: unknown): DynamicToolCallParams {
  return {
    threadId: 'thread-lead',
    turnId: 'turn-lead',
    callId: 'call-parent-input',
    namespace: null,
    tool: PARENT_INPUT_TOOL_NAME,
    arguments: argumentsValue as DynamicToolCallParams['arguments']
  }
}
