// Verifies the renderer's central guarantee: every model-view shrink (microcompact, message-context
// injection, media strip) changes only the returned context and the recorded `modelViewPatches` — the
// source rows stay byte-for-byte intact — and that those same patches replay through `trajectory.ts` to
// reproduce exactly what the model saw.
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { AiAgentConversationService } from './conversation-service'
import { HISTORICAL_MEDIA_STRIPPED_TEXT } from './media'
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

function userMessage(text: string) {
  return {
    role: 'user',
    content: [{ type: 'text', text }],
    timestamp: 0
  }
}

function userMessageWithImage(text: string) {
  return {
    role: 'user',
    content: [
      { type: 'text', text },
      { type: 'image', data: `data:image/png;base64,${'A'.repeat(100)}` }
    ],
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

    // Round-trip: feed the renderer's own refs + patches back through the trajectory rebuilder and confirm
    // the reconstructed request shows the SAME cleared content. This is what makes a microcompacted turn
    // faithfully replayable from the raw rows alone.
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

  it('adds dynamic message context to the model view while preserving the stored agent message', async () => {
    const sourceMessage = userMessage('hello')
    const rows = [
      {
        ...messageRow('u1', sourceMessage),
        role: 'user',
        metadata: {
          message_context: {
            time: { sent_at: '2026-06-09T01:00:00.000Z', injected: true },
            room: { label: 'group chat "Ops"', injected: false },
            actor: { display_name: 'Alice', injected: true }
          }
        }
      }
    ]
    const conversations = { renderedMessages: async () => rows } as unknown as AiAgentConversationService
    const renderer = new AiAgentContextRenderer(conversations)

    const rendered = await renderer.render('conv-1')
    const first = rendered.messages[0] as { content: Array<{ text: string }> }
    expect(first.content[0]!.text).toContain('<message_context>')
    expect(first.content[0]!.text).not.toContain('room: group chat "Ops"')
    expect(first.content[0]!.text).toContain('speaker: Alice')
    expect(first.content[0]!.text).toContain('hello')
    expect(sourceMessage.content[0]!.text).toBe('hello')
    expect(rendered.modelViewPatches).toHaveLength(1)
    expect(rendered.modelViewPatches[0]).toMatchObject({
      type: 'message_override',
      reason: 'message_context',
      ref: { type: 'ai_agent_message', id: 'u1', role: 'user', kind: 'normal' }
    })
  })

  it('strips older image attachments from the model view while preserving source rows', async () => {
    const firstImage = userMessageWithImage('old screenshot')
    const latestImage = userMessageWithImage('latest screenshot')
    const rows = [
      messageRow('u1', firstImage),
      messageRow('u2', userMessage('plain follow-up')),
      messageRow('u3', latestImage)
    ]
    const conversations = { renderedMessages: async () => rows } as unknown as AiAgentConversationService
    const renderer = new AiAgentContextRenderer(conversations)

    const rendered = await renderer.render('conv-1')
    const first = rendered.messages[0] as { content: Array<{ type: string; text?: string }> }
    const latest = rendered.messages[2] as { content: Array<{ type: string; text?: string }> }

    expect(first.content[0]).toEqual({ type: 'text', text: 'old screenshot' })
    expect(first.content[1]).toEqual({ type: 'text', text: HISTORICAL_MEDIA_STRIPPED_TEXT })
    expect(latest.content[1]!.type).toBe('image')
    expect((firstImage.content as Array<{ type: string }>)[1]!.type).toBe('image')
    expect(rendered.modelViewPatches).toHaveLength(1)
    expect((rendered.modelViewPatches[0] as { reason: string }).reason).toBe('historical_media_strip')
  })
})
