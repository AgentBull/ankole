import { describe, expect, it } from 'bun:test'
import type { DynamicToolCallParams } from '../src/tools/subagent/generated/protocol/v2/DynamicToolCallParams'
import {
  pendingUserInputFromDynamicTool,
  SUBAGENT_USER_INPUT_TOOL_NAME,
  subagentUserInputToolSpec
} from '../src/tools/subagent/user-input-bridge'

describe('@ankole/agent-computer subagent parent-input bridge', () => {
  it('publishes a bounded concrete tool contract for Default-mode background execution', () => {
    const spec = subagentUserInputToolSpec()

    expect(spec).toMatchObject({
      type: 'function',
      name: SUBAGENT_USER_INPUT_TOOL_NAME
    })
    if (spec.type !== 'function') throw new Error('parent-input bridge must be a function tool')
    expect(spec.description).toContain('instead of request_user_input')
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
      pendingUserInputFromDynamicTool(
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

  it('rejects malformed, oversized, and unrelated calls instead of pausing the delegation', () => {
    expect(pendingUserInputFromDynamicTool(call({ questions: [] }))).toBeUndefined()
    expect(
      pendingUserInputFromDynamicTool(
        call({
          questions: Array.from({ length: 4 }, (_value, index) => ({
            id: `question-${index}`,
            header: 'Question',
            question: 'Choose one.'
          }))
        })
      )
    ).toBeUndefined()
    expect(pendingUserInputFromDynamicTool({ ...call({ questions: [] }), tool: 'another_tool' })).toBeUndefined()
  })
})

function call(argumentsValue: unknown): DynamicToolCallParams {
  return {
    threadId: 'thread-lead',
    turnId: 'turn-lead',
    callId: 'call-parent-input',
    namespace: null,
    tool: SUBAGENT_USER_INPUT_TOOL_NAME,
    arguments: argumentsValue as DynamicToolCallParams['arguments']
  }
}
