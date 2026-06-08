import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { AiAgentConversationService } from './conversation-service'
import { MICROCOMPACT_CLEARED_TEXT } from './microcompact'

await loadTestEnvFiles()
const { AiAgentContextRenderer } = await import('./context-renderer')
const { reconstructLlmTurnTrajectory } = await import('./trajectory')

function webSearchMessage(id: string, text: string) {
  return {
    role: 'toolResult',
    toolCallId: id,
    toolName: 'web_search',
    content: [{ type: 'text', text }],
    isError: false,
    timestamp: 0
  }
}

// A 'message'-classified row needs a present agentMessage and a non-skip role/kind.
function messageRow(id: string, agentMessage: unknown) {
  return { id, role: 'tool', kind: 'normal', agentMessage, content: [], metadata: {}, createdAt: new Date() }
}

describe('AiAgentContextRenderer + microcompact', () => {
  it('returns a microcompacted model view while leaving the source rows untouched', async () => {
    const sourceMessage = webSearchMessage('s1', 'ORIGINAL SEARCH RESULT')
    const rows = [
      messageRow('s1', sourceMessage),
      messageRow('s2', webSearchMessage('s2', 'r2')),
      messageRow('s3', webSearchMessage('s3', 'r3'))
    ]
    const conversations = { renderedMessages: async () => rows } as unknown as AiAgentConversationService
    const renderer = new AiAgentContextRenderer(conversations)

    // triggerTokens: 0 forces the microcompact pass; keepRecent: 1 keeps only s3 in full.
    const rendered = await renderer.render('conv-1', { microcompact: { keepRecent: 1, triggerTokens: 0 } })

    // Model-bound view: the oldest web_search content is cleared...
    const first = rendered.messages[0] as { content: Array<{ text: string }> }
    expect(first.content[0]!.text).toBe(MICROCOMPACT_CLEARED_TEXT)
    // ...but the SOURCE row's agentMessage is byte-for-byte intact (trajectory fact preserved, no DB write).
    expect(sourceMessage.content[0]!.text).toBe('ORIGINAL SEARCH RESULT')
    expect(rendered.modelViewPatches).toHaveLength(2)
    const firstPatch = rendered.modelViewPatches[0] as {
      index: number
      message: { content: Array<{ text: string }> }
      reason: string
      ref: Record<string, unknown>
      type: string
    }
    expect(firstPatch.type).toBe('message_override')
    expect(firstPatch.reason).toBe('microcompact')
    expect(firstPatch.index).toBe(0)
    expect(firstPatch.ref).toEqual({ type: 'ai_agent_message', id: 's1', role: 'tool', kind: 'normal' })
    expect(firstPatch.message.content[0]!.text).toBe(MICROCOMPACT_CLEARED_TEXT)

    const [turn] = reconstructLlmTurnTrajectory({
      messages: rows as any,
      turns: [
        {
          id: 'turn-1',
          agentUid: 'agent-1',
          conversationId: 'conv-1',
          kind: 'generation',
          status: 'started',
          profile: 'primary',
          provider: 'provider',
          model: 'model',
          reasoning: null,
          temperature: null,
          maxTokens: null,
          cacheRetention: null,
          leaseId: 'lease-1',
          callIndex: 0,
          branchId: 'conversation:conv-1:root',
          parentBranchId: null,
          triggerMessageId: null,
          triggerEventId: null,
          inputMessageIds: ['s1', 's2', 's3'],
          inputSummaryMessageId: null,
          requestContext: { system_prompt: 'system' },
          requestRefs: rendered.inputMessageRefs,
          requestPatches: rendered.modelViewPatches,
          response: {},
          toolResults: [],
          usage: {},
          providerMetadata: {},
          startedAt: new Date('2026-01-01T00:00:00.000Z'),
          completedAt: null,
          createdAt: new Date('2026-01-01T00:00:00.000Z'),
          updatedAt: new Date('2026-01-01T00:00:00.000Z')
        }
      ] as any
    })
    expect((turn!.request.messages[0] as { content: Array<{ text: string }> }).content[0]!.text).toBe(
      MICROCOMPACT_CLEARED_TEXT
    )
  })

  it('skips microcompact when no options are passed (existing behavior unchanged)', async () => {
    const rows = [messageRow('s1', webSearchMessage('s1', 'kept')), messageRow('s2', webSearchMessage('s2', 'kept2'))]
    const conversations = { renderedMessages: async () => rows } as unknown as AiAgentConversationService
    const renderer = new AiAgentContextRenderer(conversations)

    const rendered = await renderer.render('conv-1')
    const first = rendered.messages[0] as { content: Array<{ text: string }> }
    expect(first.content[0]!.text).toBe('kept')
  })
})
