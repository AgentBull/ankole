// End-to-end tests for the AIAgent runtime against a real Postgres and Redis.
// They drive the runtime the way a chat platform would — a fake IM adapter posts
// inbound messages and records what the agent sends back — and a fake LLM provider
// returns scripted responses, so the assertions can check behaviors that are hard
// to reason about from the code alone: lease ownership/takeover across crashes,
// follow-ups and /steer surviving a turn boundary, /stop fencing, stall-watchdog
// recovery, idempotent provider redelivery, ambient (may_intervene) batching, and
// the durable LLM-turn audit trail. The shared harness lives at the bottom of the
// file (startAiAgent + helpers); read that first to follow any single test.
import { redis } from 'bun'
import { afterAll, afterEach, describe, expect, it } from 'bun:test'
import posix from 'node:path/posix'
import { and, eq, inArray, sql } from 'drizzle-orm'
import { z } from 'zod'
import { isPlainObject, ms } from '@pleisto/active-support'
import type { ComputerFile } from '@agentbull/bullx-computer'
import {
  fauxAssistantMessage,
  fauxToolCall,
  registerFauxProvider,
  type FauxProviderRegistration,
  type FauxResponseStep
} from '@/llm'
import type { JsonObject } from '@/common/db-schema'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { AiAgentRuntimeProfile } from './config'
import { AiAgentClarifyRegistry } from './clarify-registry'
import type { ExternalGatewayAdapterCapabilities } from '@/external-gateway/core'
import type {
  MockImConversationOptions,
  MockImPlatform as MockImPlatformInstance
} from '@/external-gateway/testing/mock-im-adapter'
import type { AgentTool } from './core'

await loadTestEnvFiles()

// Everything below is imported dynamically, after the test env files load, so the
// DB/Redis connection settings are in place before any module reads them at import
// time. Static `import` would bind those modules before loadTestEnvFiles() runs.
const { DB, jsonbParam } = await import('@/common/database')
const {
  AiAgentConversations,
  AiAgentCheckbacks,
  AiAgentLlmTurns,
  AiAgentMessages,
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  ExternalGatewayOutbox,
  ExternalMessages,
  ExternalRooms,
  Principals
} = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const { ExternalGatewayRuntime } = await import('@/external-gateway/runtime')
const { registerExternalGatewayAdapterFactory } = await import('@/external-gateway/adapter-registry')
const {
  fullMockImCapabilities,
  mockImCapabilitiesWithout,
  MockImPlatform: MockImPlatformCtor
} = await import('@/external-gateway/testing/mock-im-adapter')
const { AiAgentRuntime } = await import('./runtime')
const { SchedulerRuntime } = await import('@/scheduler/runtime')
const { reconstructLlmTurnTrajectory, selectExportableGenerationLeases } = await import('./trajectory')
const { aiAgentConversationService, providerRefs, textContent, textFromContent } =
  await import('./conversation-service')
const { AiAgentRuntimeConfigDefinition } = await import('./config')
const { appConfigService } = await import('@/config/app-configure')
const { createUserMessage } = await import('./core')
const { buildTool } = await import('./tools/build-tool')
const { AiAgentAmbientBatcher } = await import('./ambient')
const { externalGatewayOutbox } = await import('@/external-gateway/outbox')
const { externalGatewayProjectionSink } = await import('@/external-gateway/core/projection')

// Unique per test run. Every agent, room, and Redis member this file creates is
// keyed by it so afterAll can delete exactly this run's rows and leave any other
// data in the shared database untouched.
const testPrefix = `ai_agent_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const AMBIENT_REDIS_KEY = 'bullx-agent:ai-agent:ambient-wake'
// Resources accumulated across tests, drained by the afterEach/afterAll hooks
// below. Runtimes and provider registrations are torn down every test; DB rows and
// Redis wake members are cleaned once at the end since they are keyed by agent uid.
const agentUids = new Set<string>()
const projectedRoomIds = new Set<string>()
const runtimes = new Set<InstanceType<typeof ExternalGatewayRuntime>>()
const fauxRegistrations = new Set<FauxProviderRegistration>()

afterEach(async () => {
  for (const runtime of runtimes) await runtime.stop()
  runtimes.clear()
  for (const registration of fauxRegistrations) registration.unregister()
  fauxRegistrations.clear()
})

afterAll(async () => {
  await clearAmbientRedisMembersForTestPrefix()
  for (const agentUid of agentUids) {
    await DB.delete(AiAgentCheckbacks).where(eq(AiAgentCheckbacks.agentUid, agentUid))
    await DB.delete(AiAgentLlmTurns).where(eq(AiAgentLlmTurns.agentUid, agentUid))
    await DB.delete(AiAgentMessages).where(eq(AiAgentMessages.agentUid, agentUid))
    await DB.delete(AiAgentConversations).where(eq(AiAgentConversations.agentUid, agentUid))
    await DB.delete(ExternalGatewayOutbox).where(eq(ExternalGatewayOutbox.agentUid, agentUid))
    await DB.delete(ExternalGatewayAgentEvents).where(eq(ExternalGatewayAgentEvents.agentUid, agentUid))
    await DB.delete(ExternalGatewayInputTombstones).where(eq(ExternalGatewayInputTombstones.agentUid, agentUid))
    await DB.delete(Principals).where(eq(Principals.uid, agentUid))
  }
  for (const roomId of projectedRoomIds) await DB.delete(ExternalRooms).where(eq(ExternalRooms.id, roomId))
})

describe('AIAgent AI SDK runtime', () => {
  it('runs multi-turn pure text, audits LLM turns, and keys conversation by room not thread', async () => {
    const setup = await startAiAgent('multi_turn', [
      fauxAssistantMessage('first answer'),
      fauxAssistantMessage('second answer')
    ])
    const roomId = `${setup.adapterName}:room`
    const first = setup.platform.group(setup.conversationOptions({ channelId: roomId, threadId: `${roomId}:thread-a` }))
    const second = setup.platform.group(
      setup.conversationOptions({ channelId: roomId, threadId: `${roomId}:thread-b` })
    )

    await first.say({ id: 'm1', isMention: true, text: '@Agent hello' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
    await second.say({ id: 'm2', isMention: true, text: '@Agent continue' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(2))

    expect(setup.platform.outbound.map(event => event.text)).toEqual(['first answer', 'second answer'])
    const conversations = await conversationsFor(setup.agentUid)
    expect(conversations).toHaveLength(1)
    expect(conversations[0]!.conversationKey).toContain(`room:${roomId}`)
    expect(conversations[0]!.conversationKey).not.toContain('thread-a')
    expect(conversations[0]!.conversationKey).not.toContain('thread-b')

    const messages = await messagesFor(conversations[0]!.id)
    expect(messages.map(row => `${row.role}:${row.kind}`)).toEqual([
      'user:normal',
      'assistant:normal',
      'user:normal',
      'assistant:normal'
    ])
    const turns = await llmTurnsFor(conversations[0]!.id)
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toEqual([
      'generation:primary:primary',
      'generation:primary:primary'
    ])
    expect(turns.map(row => row.provider)).toEqual([
      setup.profile.primaryModel.config.providerId,
      setup.profile.primaryModel.config.providerId
    ])
    expect(
      turns.every(
        row => (row.providerMetadata as JsonObject).llm_provider === setup.profile.primaryModel.config.llmProvider
      )
    ).toBe(true)
    expect(turns.every(row => row.status === 'succeeded')).toBe(true)
    expect(turns.every(row => typeof (row.usage as { totalTokens?: unknown }).totalTokens === 'number')).toBe(true)
    expect(reconstructLlmTurnTrajectory({ turns, messages }).every(turn => turn.request.exactLlmRequest)).toBe(true)
    expect((turns[0]!.requestContext as JsonObject).system_prompt).not.toContain('<tool_routing_policy>')
    expect((turns[0]!.requestContext as JsonObject).system_prompt).not.toContain('chat_history_search')
  })

  it('renders chat-history routing policy only when chat recall is enabled', async () => {
    const setup = await startAiAgent('chat_recall_prompt', [fauxAssistantMessage('answer')], { enableChatRecall: true })
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent what did we previously discuss about launch risk?' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'answer')).toBe(true))

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    const systemPrompt = (turns[0]!.requestContext as JsonObject).system_prompt
    expect(systemPrompt).toContain('<tool_routing_policy>')
    expect(systemPrompt).toContain('chat_history_search is available in this request')
    expect(systemPrompt).toContain('recalled chat context, not new user input')
  })

  it('materializes inbound image attachments into model-visible image blocks', async () => {
    const setup = await startAiAgent('inbound_image_context', [fauxAssistantMessage('saw image')])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({
      attachments: [
        {
          data: Buffer.from(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
            'base64'
          ),
          mimeType: 'image/png',
          name: 'pixel.png',
          type: 'image'
        }
      ],
      id: 'm-image',
      text: 'describe this image'
    })

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'saw image')).toBe(true))
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    const imageMessage = rows.find(row => row.role === 'user' && textOf(row.content).includes('describe this image'))
    const content = (imageMessage?.agentMessage as any)?.content

    expect(content?.[0]).toMatchObject({ type: 'text', text: expect.stringContaining('describe this image') })
    expect(content?.[1]).toMatchObject({ type: 'image', mimeType: 'image/png' })
    expect(typeof content?.[1]?.data).toBe('string')
    expect(content?.[1]?.data.length).toBeGreaterThan(20)
  })

  it('does not send materialized image cache paths as model-visible text', async () => {
    const setup = await startAiAgent('inbound_image_text_cleanup', [fauxAssistantMessage('saw image')])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({
      attachments: [
        {
          data: Buffer.from(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
            'base64'
          ),
          mimeType: 'image/png',
          name: 'pixel.png',
          type: 'image'
        }
      ],
      id: 'm-image-path',
      text: "![image](img_v3_test)\n\n[image 'image' saved at: /workspace/user-files/external-gateway/lark/lark/om_test/image.jpg]"
    })

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'saw image')).toBe(true))
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    const imageMessage = rows.find(row => row.role === 'user')
    const content = (imageMessage?.agentMessage as any)?.content

    expect(content?.[0]).toEqual({ type: 'text', text: '[Image attached]' })
    expect(content?.[1]).toMatchObject({ type: 'image', mimeType: 'image/png' })
  })

  it('starts generation for pure attachment messages after the media batch window', async () => {
    const setup = await startAiAgent('attachment_only_media_delay', [fauxAssistantMessage('saw attachment')], {
      addressedMediaBatchWindowMs: 5
    })
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({
      attachments: [
        {
          data: Buffer.from('hello document'),
          mimeType: 'text/plain',
          name: 'note.txt',
          type: 'file'
        }
      ],
      id: 'm-file-only',
      text: ''
    })

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'saw attachment')).toBe(true))
    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.filter(row => row.kind === 'generation')).toHaveLength(1)
    const trigger = (await messagesFor(conversation!.id)).find(row => providerMessageIds(row).includes('m-file-only'))
    expect(turns[0]!.triggerMessageId).toBe(trigger!.id)
  })

  it('coalesces a pure attachment followed by text into one generation triggered by the text', async () => {
    const setup = await startAiAgent(
      'attachment_then_text_media_delay',
      [fauxAssistantMessage('read with instruction')],
      {
        addressedMediaBatchWindowMs: 1_000
      }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({
      attachments: [
        {
          data: Buffer.from('contract body'),
          mimeType: 'text/plain',
          name: 'contract.txt',
          type: 'file'
        }
      ],
      id: 'm-file-first',
      text: ''
    })
    await dm.say({ id: 'm-text-second', text: 'Please summarize the file.' })

    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'read with instruction')).toBe(true)
    )
    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    expect(turns).toHaveLength(1)
    const rows = await messagesFor(conversation!.id)
    const textTrigger = rows.find(row => providerMessageIds(row).includes('m-text-second'))
    expect(turns[0]!.triggerMessageId).toBe(textTrigger!.id)
    expect(rows.some(row => providerMessageIds(row).includes('m-file-first'))).toBe(true)
  })

  it('deduplicates provider redelivery before it can duplicate transcript or output', async () => {
    const setup = await startAiAgent('redelivery', [fauxAssistantMessage('single answer')])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'same provider event' })
    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.text === 'single answer')).toHaveLength(1)
    )
    await dm.say({ id: 'm1', text: 'same provider event' })
    await Bun.sleep(160)

    expect(setup.platform.outbound.filter(event => event.text === 'single answer')).toHaveLength(1)
    const [conversation] = await conversationsFor(setup.agentUid)
    const messages = await messagesFor(conversation!.id)
    expect(messages.filter(row => row.role === 'user' && providerMessageIds(row).includes('m1'))).toHaveLength(1)
    expect(messages.filter(row => row.role === 'assistant' && textOf(row.content) === 'single answer')).toHaveLength(1)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.filter(row => row.kind === 'generation')).toHaveLength(1)
  })

  it('compresses with the light model profile and emits one final command feedback', async () => {
    const setup = await startAiAgent(
      'compress',
      [
        fauxAssistantMessage('answer one'),
        fauxAssistantMessage('answer two'),
        fauxAssistantMessage('summary text'),
        // Real upstream compaction split-turns under keepRecentTokens=1, so it also summarizes the turn
        // prefix — a second light-model call the fake compaction never made.
        fauxAssistantMessage('turn prefix summary')
      ],
      { compressionKeepRecentTokens: 1 }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'first user message that is long enough' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.text === 'answer one')).toHaveLength(1))
    await dm.say({ id: 'm2', text: 'second user message that is long enough' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.text === 'answer two')).toHaveLength(1))
    await dm.say({ id: 'compress-command', text: '/compress' })

    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.text === 'Conversation compressed.')).toHaveLength(1)
    )
    expect(setup.platform.outbound.some(event => event.op === 'edit')).toBe(false)
    expect(setup.platform.outbound.some(event => event.text === 'Compressing conversation...')).toBe(false)

    const [conversation] = await conversationsFor(setup.agentUid)
    const summaries = (await messagesFor(conversation!.id)).filter(row => row.kind === 'summary')
    expect(summaries).toHaveLength(1)
    // Split-turn compaction composes the history summary with a separate turn-prefix summary.
    expect(textOf(summaries[0]!.content)).toContain('summary text')
    expect(textOf(summaries[0]!.content)).toContain('**Turn Context (split turn):**')
    const turns = await llmTurnsFor(conversation!.id)
    const compressionTurns = turns
      .filter(row => row.kind === 'compression' && row.profile === 'light' && row.model === 'light')
      .slice()
      .sort((a, b) => (a.callIndex ?? 0) - (b.callIndex ?? 0))
    expect(compressionTurns.length).toBeGreaterThanOrEqual(1)
    const compressionTurn = compressionTurns[0]!
    expect(compressionTurns.map(row => row.callIndex)).toEqual(compressionTurns.map((_, index) => index))
    expect(new Set(compressionTurns.map(row => row.leaseId))).toEqual(new Set([compressionTurn?.leaseId]))
    expect(compressionTurns.every(row => jsonObjects(row.requestRefs).length > 0)).toBe(true)
    expect(
      compressionTurns.every(row =>
        jsonObjects(row.requestPatches).some(patch => patch.type === 'llm_request' && patch.reason === 'compaction')
      )
    ).toBe(true)
    expect(jsonRecord(summaries[0]!.metadata.compression)?.llm_turn_ids).toEqual(compressionTurns.map(row => row.id))
    expect(compressionTurn.provider).toBe(setup.profile.lightModel.config.providerId)
    expect((compressionTurn.providerMetadata as JsonObject | undefined)?.llm_provider).toBe(
      setup.profile.lightModel.config.llmProvider
    )
  })

  it('compresses from a mentioned group command without posting progress chatter', async () => {
    const setup = await startAiAgent(
      'compress_group',
      [
        fauxAssistantMessage('group answer one'),
        fauxAssistantMessage('group answer two'),
        fauxAssistantMessage('group summary text'),
        fauxAssistantMessage('group turn prefix summary')
      ],
      { compressionKeepRecentTokens: 1 }
    )
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent first group message that is long enough' })
    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.text === 'group answer one')).toHaveLength(1)
    )
    await group.say({ id: 'm2', isMention: true, text: '@Agent second group message that is long enough' })
    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.text === 'group answer two')).toHaveLength(1)
    )
    await group.say({ id: 'compress-command', isMention: true, text: '@Agent /compress' })

    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.text === 'Conversation compressed.')).toHaveLength(1)
    )
    expect(setup.platform.outbound.some(event => event.op === 'edit')).toBe(false)
    expect(setup.platform.outbound.some(event => event.text === 'Compressing conversation...')).toBe(false)
  })

  it('retries the latest exchange without removing the original user trigger', async () => {
    const setup = await startAiAgent('retry', [
      fauxAssistantMessage('old answer'),
      fauxAssistantMessage('retry answer')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'question' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.text === 'old answer')).toHaveLength(1))
    await dm.say({ id: 'retry-command', text: '/retry' })

    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.text === 'retry answer')).toHaveLength(1)
    )
    expect(setup.platform.outbound.some(event => event.op === 'delete')).toBe(true)
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      const messages = await messagesFor(conversation!.id)
      const user = messages.find(row => row.role === 'user' && row.eventId === 'm1')
      const assistants = messages.filter(row => row.role === 'assistant')
      expect(transcriptEffect(user)).toBeUndefined()
      expect(assistants.map(row => transcriptEffect(row))).toEqual(['superseded', undefined])
    })
    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    const messages = await messagesFor(conversation!.id)
    const leases = selectExportableGenerationLeases(turns, messages)
    expect(leases).toHaveLength(1)
    const selectedTurnIds = new Set(leases[0]!.turnIds)
    const selectedTurns = turns.filter(row => selectedTurnIds.has(row.id))
    expect(selectedTurns.map(row => row.kind)).toEqual(['retry_generation'])
    expect(reconstructLlmTurnTrajectory({ turns: selectedTurns, messages })[0]!.request.exactLlmRequest).toBe(true)
    // Tools are always offered; the model decides whether to use them.
    expect(Number((selectedTurns[0]?.requestContext as JsonObject | undefined)?.tool_count)).toBeGreaterThan(0)
    expect(selectedTurns.some(row => JSON.stringify(row.response).includes('old answer'))).toBe(false)
    expect(selectedTurns.some(row => JSON.stringify(row.response).includes('retry answer'))).toBe(true)
  })

  it('keeps tools enabled when retrying a multi-turn generation that previously used tools', async () => {
    const lookupTool = buildTool({
      name: 'lookup_budget',
      label: 'Lookup budget',
      description: 'Looks up a budget fact.',
      schema: z.object({ query: z.string() }),
      async execute(_toolCallId, params) {
        return {
          content: [{ type: 'text', text: `budget result for ${params.query}: 8500` }],
          details: { value: 8500 }
        }
      }
    })
    const setup = await startAiAgent(
      'retry_tool_generation',
      [
        fauxAssistantMessage([fauxToolCall('lookup_budget', { query: 'outing' })]),
        fauxAssistantMessage('partial search note', {
          errorMessage: 'Upstream idle timeout exceeded',
          stopReason: 'error'
        }),
        fauxAssistantMessage([fauxToolCall('lookup_budget', { query: 'outing' })]),
        fauxAssistantMessage('retry answer with 8500')
      ],
      { tools: [lookupTool] }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'what is the outing budget?' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      const turns = await llmTurnsFor(conversation!.id)
      expect(turns.some(row => row.status === 'failed')).toBe(true)
    })
    await dm.say({ id: 'retry-command', text: '/retry' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'retry answer with 8500')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const retryTurns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'retry_generation')
    const messages = await messagesFor(conversation!.id)
    expect(retryTurns).toHaveLength(2)
    expect(
      reconstructLlmTurnTrajectory({ turns: retryTurns, messages }).map(turn => turn.request.exactLlmRequest)
    ).toEqual([true, true])
    expect(
      retryTurns.every(row => {
        const toolCount = (row.requestContext as JsonObject | undefined)?.tool_count
        return typeof toolCount === 'number' && toolCount > 0
      })
    ).toBe(true)
    expect((retryTurns[0]!.requestContext as JsonObject | undefined)?.tool_names).toContain('lookup_budget')
    expect(JSON.stringify(retryTurns[0]!.response)).toContain('lookup_budget')
  })

  it('handles latest and historical IM recall without hallucinating away old turns', async () => {
    const latest = await startAiAgent('recall_latest', [fauxAssistantMessage('latest answer')])
    const latestGroup = latest.platform.group(latest.conversationOptions({ channelId: `${latest.adapterName}:room` }))
    await latestGroup.say({ id: 'm1', isMention: true, text: '@Agent latest' })
    await eventually(() =>
      expect(latest.platform.outbound.filter(event => event.text === 'latest answer')).toHaveLength(1)
    )
    await latestGroup.recall('m1')
    await eventually(() => expect(latest.platform.outbound.some(event => event.op === 'delete')).toBe(true))

    await eventually(async () => {
      const [latestConversation] = await conversationsFor(latest.agentUid)
      expect((await messagesFor(latestConversation!.id)).map(row => transcriptEffect(row))).toEqual([
        'recalled',
        'recalled'
      ])
    })

    const historical = await startAiAgent('recall_historical', [
      fauxAssistantMessage('first answer'),
      fauxAssistantMessage('second answer')
    ])
    const group = historical.platform.group(
      historical.conversationOptions({ channelId: `${historical.adapterName}:room` })
    )
    await group.say({ id: 'm1', isMention: true, text: '@Agent first' })
    await eventually(() =>
      expect(historical.platform.outbound.filter(event => event.text === 'first answer')).toHaveLength(1)
    )
    await group.say({ id: 'm2', isMention: true, text: '@Agent second' })
    await eventually(() =>
      expect(historical.platform.outbound.filter(event => event.text === 'second answer')).toHaveLength(1)
    )
    await group.recall('m1')

    const [historicalConversation] = await conversationsFor(historical.agentUid)
    await eventually(async () => {
      const rows = await messagesFor(historicalConversation!.id)
      expect(rows.some(row => row.kind === 'introspection')).toBe(true)
    })
    expect(historical.platform.outbound.some(event => event.op === 'delete')).toBe(false)
  })

  it('ignores recall targets hidden behind compression or ended conversations', async () => {
    const compressed = await startAiAgent(
      'recall_compressed',
      [
        fauxAssistantMessage('first answer'),
        fauxAssistantMessage('second answer'),
        fauxAssistantMessage('summary text'),
        // Split-turn compaction makes a second (turn-prefix) light-model call; supply its faux response so
        // compression succeeds and m1 is actually compressed away.
        fauxAssistantMessage('turn prefix summary')
      ],
      { compressionKeepRecentTokens: 1 }
    )
    const compressedGroup = compressed.platform.group(
      compressed.conversationOptions({ channelId: `${compressed.adapterName}:room` })
    )
    await compressedGroup.say({ id: 'm1', isMention: true, text: '@Agent first compressed-away turn' })
    await eventually(() => expect(compressed.platform.outbound.some(event => event.text === 'first answer')).toBe(true))
    await compressedGroup.say({ id: 'm2', isMention: true, text: '@Agent second kept turn' })
    await eventually(() =>
      expect(compressed.platform.outbound.some(event => event.text === 'second answer')).toBe(true)
    )
    await compressedGroup.say({ id: 'compress-command', isMention: true, text: '/compress' })
    await eventually(() =>
      expect(compressed.platform.outbound.some(event => event.text === 'Conversation compressed.')).toBe(true)
    )
    await compressedGroup.recall('m1')
    await Bun.sleep(120)

    const [compressedConversation] = await conversationsFor(compressed.agentUid)
    const compressedRows = await messagesFor(compressedConversation!.id)
    expect(compressedRows.filter(row => row.kind === 'introspection')).toHaveLength(0)
    expect(
      compressedRows.find(row => row.eventId === 'm1' && row.role === 'user')?.metadata.transcript_effect
    ).toBeUndefined()
    expect(compressed.platform.outbound.some(event => event.op === 'delete')).toBe(false)

    const ended = await startAiAgent('recall_ended', [fauxAssistantMessage('old answer')])
    const endedGroup = ended.platform.group(ended.conversationOptions({ channelId: `${ended.adapterName}:room` }))
    await endedGroup.say({ id: 'm1', isMention: true, text: '@Agent old session' })
    await eventually(() => expect(ended.platform.outbound.some(event => event.text === 'old answer')).toBe(true))
    await endedGroup.say({ id: 'new-command', isMention: true, text: '/new' })
    await eventually(() => expect(ended.platform.outbound.some(event => event.text === 'New conversation')).toBe(true))
    await endedGroup.recall('m1')
    await Bun.sleep(120)

    const endedConversations = await conversationsFor(ended.agentUid)
    expect(endedConversations).toHaveLength(2)
    const oldConversation = endedConversations.find(row => row.endedAt)!
    const oldRows = await messagesFor(oldConversation.id)
    expect(oldRows.map(row => transcriptEffect(row))).toEqual([undefined, undefined])
    expect(ended.platform.outbound.some(event => event.op === 'delete')).toBe(false)
  })

  it('starts a fresh generation when /new includes a follow-up message', async () => {
    const setup = await startAiAgent('new_with_message', [
      fauxAssistantMessage('old answer'),
      fauxAssistantMessage('fresh answer')
    ])
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:room` }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent old session' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'old answer')).toBe(true))
    await group.say({ id: 'new-with-message', isMention: true, text: '/new fresh task' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'fresh answer')).toBe(true))

    const conversations = await conversationsFor(setup.agentUid)
    expect(conversations).toHaveLength(2)
    const freshConversation = conversations.find(row => !row.endedAt)!
    const rows = await messagesFor(freshConversation.id)
    expect(rows.map(row => `${row.role}:${row.kind}:${textOf(row.content)}`)).toEqual([
      'user:normal:fresh task',
      'assistant:normal:fresh answer'
    ])
  })

  // The anchor test for ambient (may_intervene) mode: a room message the agent is
  // not @mentioned in first runs a cheap "should I jump in?" recognizer on the light
  // model; only a positive decision spends the primary model on a real answer. The
  // bulk of the assertions pin the recognizer's prompt/IO contract and one subtle
  // continuity rule: the recognizer's decision is persisted as an `im_ambient`
  // introspection message, and the addressed generation that follows must take that
  // same message as input (inputMessageIds) so the visible reply is anchored to what
  // the agent decided to act on. Raw user text like `<ticket-7>` must reach the model
  // un-escaped (no `&lt;`), since HTML-escaping it would corrupt the content.
  it('batches ambient may_intervene inside AIAgent and routes recognizer through the light model profile', async () => {
    const setup = await startAiAgent(
      'ambient',
      [
        fauxAssistantMessage('{"intervene":false}'),
        fauxAssistantMessage('```json\n{"intervene":true,"reason_summary":"asked for help"}\n```'),
        fauxAssistantMessage('ambient answer'),
        fauxAssistantMessage('addressed after ambient'),
        fauxAssistantMessage('{"intervene":true,"reason_summary":"second help"}'),
        fauxAssistantMessage('second ambient answer')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 10 }
    )
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:ambient` }))

    await group.say({ id: 'a1', text: 'just chatting' })
    await Bun.sleep(80)
    expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(0)

    await group.say({ id: 'a2', text: 'agent should help here <ticket-7>' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'ambient answer')).toBe(true))

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toContain('ambient_recognizer:light:light')
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toContain('generation:primary:primary')
    const ambientTurn = turns.filter(row => row.kind === 'ambient_recognizer').at(-1)
    const ambientGeneration = turns.find(row => row.kind === 'generation')
    expect(ambientTurn?.provider).toBe(setup.profile.lightModel.config.providerId)
    expect(ambientTurn?.callIndex).toBe(0)
    expect(ambientTurn?.leaseId).toBeTruthy()
    expect(jsonObjects(ambientTurn?.requestRefs)).not.toHaveLength(0)
    const ambientRecognizerRequest = jsonObjects(ambientTurn?.requestPatches).find(
      patch => patch.type === 'llm_request' && patch.reason === 'ambient_recognizer'
    )
    expect(ambientRecognizerRequest).toBeTruthy()
    const recognizerMessages = Array.isArray(ambientRecognizerRequest?.messages)
      ? (ambientRecognizerRequest.messages as Array<Record<string, unknown>>)
      : []
    const recognizerContent = recognizerMessages[0]?.content
    const recognizerText = typeof recognizerContent === 'string' ? recognizerContent : textOf(recognizerContent)
    expect(ambientRecognizerRequest?.system_prompt).toContain('You are deciding whether')
    expect(ambientRecognizerRequest?.system_prompt).toContain('<agent_identity>')
    expect(ambientRecognizerRequest?.system_prompt).toContain('<agent_soul>')
    expect(ambientRecognizerRequest?.system_prompt).toContain('<runtime_context>')
    expect(ambientRecognizerRequest?.system_prompt).toContain(`uid: ${setup.agentUid}`)
    expect(ambientRecognizerRequest?.system_prompt).toContain(
      `current_channel: group chat ${setup.adapterName}:ambient`
    )
    expect(ambientRecognizerRequest?.response_format).toMatchObject({
      type: 'json_schema',
      name: 'ambient_intervention_decision'
    })
    expect(recognizerText).toContain('<im_intervention_decision_input format="yaml">')
    expect(recognizerText).toContain('decision_task: decide_if_agent_should_visibly_reply_now')
    expect(recognizerText).toContain('current_observed_messages:')
    expect(recognizerText).toContain('recent_visible_transcript:')
    expect(recognizerText).toContain('earlier_observed_messages_since_last_reply:')
    expect(recognizerText).toContain('agent should help here <ticket-7>')
    expect(recognizerText).not.toContain('&lt;ticket-7&gt;')
    expect(recognizerText).not.toContain('Recent ambient room messages:')
    expect((ambientTurn?.providerMetadata as JsonObject | undefined)?.llm_provider).toBe(
      setup.profile.lightModel.config.llmProvider
    )
    const ambientGenerationContext = ambientGeneration?.requestContext as Record<string, unknown> | undefined
    const ambientGenerationToolNames = ambientGenerationContext?.tool_names as string[] | undefined
    expect(ambientGenerationContext?.tool_count).toBeGreaterThan(0)
    expect(ambientGenerationToolNames).toContain('todo')
    expect(ambientGenerationContext?.system_prompt).toContain('<message_context_policy>')
    expect(ambientGenerationContext?.system_prompt).not.toContain('<ambient_intervention_policy>')
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'im_ambient' && row.kind === 'normal')).toBe(true)
    const introspection = rows.find(row => row.role === 'im_ambient' && row.kind === 'introspection')
    expect(introspection).toBeTruthy()
    expect(textOf(introspection?.content)).toContain('<chat_segment format="yaml">')
    expect(textOf(introspection?.content)).toContain('messages:')
    expect(textOf(introspection?.content)).toContain('agent should help here <ticket-7>')
    expect(textOf(introspection?.content)).not.toContain('&lt;ticket-7&gt;')
    expect(textOf(introspection?.content)).not.toContain('<chat_message')
    expect(textOf(introspection?.content)).not.toContain('Ambient intervention trigger')
    const ambientGenerationRequest = jsonObjects(ambientGeneration?.requestPatches).find(
      patch => patch.type === 'llm_request'
    )
    const generationMessages = Array.isArray(ambientGenerationRequest?.messages)
      ? (ambientGenerationRequest.messages as Array<Record<string, unknown>>)
      : []
    const firstGenerationText = textOf(generationMessages[0]?.content)
    expect(firstGenerationText).toContain('<message_context>')
    expect(firstGenerationText).toContain(`speaker: ${setup.agentUid}`)
    expect(firstGenerationText).toContain('speaker_role: agent')
    expect(firstGenerationText).toContain('speaker_trigger: introspection')
    expect(firstGenerationText).toContain('think: BullX runtime generated this user-role message')
    expect(firstGenerationText).toContain('The outer message is a BullX runtime instruction')
    expect(firstGenerationText).toContain('inside <chat_segment>')
    expect(firstGenerationText).toContain('<chat_segment format="yaml">')
    expect(firstGenerationText).not.toContain('<ambient_references')

    await group.say({ id: 'm3', isMention: true, text: '@Agent continue from intervention' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'addressed after ambient')).toBe(true)
    )
    const updatedTurns = await llmTurnsFor(conversation!.id)
    const latestGeneration = updatedTurns.filter(row => row.kind === 'generation').at(-1)!
    expect(latestGeneration.inputMessageIds).toContain(introspection!.id)

    await group.say({ id: 'a3', text: 'another ambient help request' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'second ambient answer')).toBe(true)
    )
    const finalTurns = await llmTurnsFor(conversation!.id)
    const latestAmbientTurn = finalTurns.filter(row => row.kind === 'ambient_recognizer').at(-1)!
    expect(latestAmbientTurn.inputMessageIds).toHaveLength(1)
    const latestAmbientMessage = (await messagesFor(conversation!.id)).find(
      row => row.role === 'im_ambient' && row.kind === 'normal' && textOf(row.content).includes('another ambient help')
    )
    expect(latestAmbientTurn.inputMessageIds).toEqual([latestAmbientMessage!.id])
  })

  it('coalesces concurrent ambient drains for one batch', async () => {
    const setup = await startAiAgent(
      'ambient_batch_once',
      [fauxAssistantMessage('{"intervene":true,"reason_summary":"demo prep"}')],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 250 }
    )
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:ambient-batch` }))

    await Promise.all([
      group.say({ id: 'b1', text: 'demo env needs prep' }),
      group.say({ id: 'b2', text: 'demo data needs prep' }),
      group.say({ id: 'b3', text: 'projector needs testing' })
    ])

    const [conversation] = await conversationsFor(setup.agentUid)
    await eventually(async () => {
      const turns = await llmTurnsFor(conversation!.id)
      expect(turns.filter(row => row.kind === 'ambient_recognizer')).toHaveLength(1)
    })
    const turns = await llmTurnsFor(conversation!.id)
    const ambientTurns = turns.filter(row => row.kind === 'ambient_recognizer')
    expect(ambientTurns[0]!.inputMessageIds).toHaveLength(3)

    await eventually(async () => {
      const rows = await messagesFor(conversation!.id)
      expect(rows.filter(row => row.role === 'im_ambient' && row.kind === 'introspection')).toHaveLength(1)
    })
  })

  // The next four tests are one family: small models often ignore the requested JSON
  // schema and answer the intervene/skip question in broken JSON, fenced YAML, terse
  // YAML, or XML-ish tags. Rather than waste the decision, the recognizer parser
  // salvages a clear "intervene" out of each shape. Losing these would make the agent
  // silently miss rooms that explicitly asked for help.
  it('recovers ambient intervention when recognizer JSON is malformed but the decision is clear', async () => {
    const setup = await startAiAgent(
      'ambient_malformed_json',
      [
        fauxAssistantMessage('{"intervene": true, "reason_summary": "asked "who can help"'),
        fauxAssistantMessage('ambient recovered answer')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 10 }
    )
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:ambient-repair` }))

    await group.say({ id: 'm1', text: 'who can help search history?' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'ambient recovered answer')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    const recognizer = turns.find(row => row.kind === 'ambient_recognizer')
    expect(recognizer?.status).toBe('succeeded')
    expect((recognizer?.response as JsonObject | undefined)?.raw_text).toContain('"intervene": true')
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'im_ambient' && row.kind === 'introspection')).toBe(true)
  })

  it('recovers ambient intervention when recognizer returns fenced YAML decision fields', async () => {
    const setup = await startAiAgent(
      'ambient_yaml_decision',
      [
        fauxAssistantMessage(
          [
            '```yaml',
            'im_intervention_decision:',
            '  should_intervene: true',
            '  reason: |',
            '    The room explicitly asked the agent to step in.',
            '```'
          ].join('\n')
        ),
        fauxAssistantMessage('ambient yaml answer')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 10 }
    )
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:ambient-yaml` }))

    await group.say({ id: 'm1', text: '@Agent please help me now' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'ambient yaml answer')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    const recognizer = turns.find(row => row.kind === 'ambient_recognizer')
    expect(recognizer?.status).toBe('succeeded')
    expect((recognizer?.response as JsonObject | undefined)?.parsed).toMatchObject({
      intervene: true,
      reason_summary: 'The room explicitly asked the agent to step in.'
    })
  })

  it('recovers ambient intervention when recognizer returns terse YAML decision text', async () => {
    const setup = await startAiAgent(
      'ambient_yaml_decision_word',
      [
        fauxAssistantMessage(
          [
            '```yaml',
            'decision: intervene',
            'reasoning: The room explicitly asked the agent to step in.',
            'confidence: high',
            '```'
          ].join('\n')
        ),
        fauxAssistantMessage('ambient yaml decision word answer')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 10 }
    )
    const group = setup.platform.group(
      setup.conversationOptions({ channelId: `${setup.adapterName}:ambient-yaml-decision-word` })
    )

    await group.say({ id: 'm1', text: '@Agent please help me now' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'ambient yaml decision word answer')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    const recognizer = turns.find(row => row.kind === 'ambient_recognizer')
    expect(recognizer?.status).toBe('succeeded')
    expect((recognizer?.response as JsonObject | undefined)?.parsed).toMatchObject({
      intervene: true,
      reason_summary: 'The room explicitly asked the agent to step in.'
    })
  })

  it('recovers ambient intervention when recognizer returns XML-like decision fields', async () => {
    const setup = await startAiAgent(
      'ambient_xml_decision',
      [
        fauxAssistantMessage(
          [
            '<im_intervention_decision>',
            '  <decision>intervene</decision>',
            '  <reasoning>The room explicitly asked the agent to step in.</reasoning>',
            '</im_intervention_decision>'
          ].join('\n')
        ),
        fauxAssistantMessage('ambient xml answer')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 10 }
    )
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:ambient-xml` }))

    await group.say({ id: 'm1', text: '@Agent please help me now' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'ambient xml answer')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    const recognizer = turns.find(row => row.kind === 'ambient_recognizer')
    expect(recognizer?.status).toBe('succeeded')
    expect((recognizer?.response as JsonObject | undefined)?.parsed).toMatchObject({
      intervene: true,
      reason_summary: 'The room explicitly asked the agent to step in.'
    })
  })

  it('runs conversations of one agent in parallel lanes (different rooms do not queue)', async () => {
    const releases: Array<() => void> = []
    const blocked = Array.from({ length: 3 }, () => {
      let release!: () => void
      const gate = new Promise<void>(resolve => {
        release = resolve
      })
      releases.push(release)
      return async () => {
        await gate
        return fauxAssistantMessage('parallel answer')
      }
    })
    const setup = await startAiAgent('lane_parallel', blocked)

    for (const index of [0, 1, 2]) {
      const room = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:lane-${index}` }))
      await room.say({ id: `m-${index}`, text: `@Agent hello ${index}`, isMention: true })
    }

    // All three rooms hold an active generation lease at the same time.
    await eventually(async () => {
      const conversations = await conversationsFor(setup.agentUid)
      const active = conversations.filter(
        row => !row.endedAt && row.generation.lease_id && !row.generation.cancelled_at
      )
      expect(active.length).toBe(3)
    })

    for (const release of releases) release()
    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.text === 'parallel answer').length).toBe(3)
    )
  })

  it('caps in-flight conversations at maxConversationsPerAgent and frees the slot afterwards', async () => {
    // The profile default is 16 lanes; override it to 2 via app config so a third
    // concurrent room is forced to queue. Restored in the finally so it cannot leak
    // into the next test (app config is shared global state).
    await appConfigService.set(AiAgentRuntimeConfigDefinition, { parallelism: { maxConversationsPerAgent: 2 } })
    try {
      const releases: Array<() => void> = []
      const blocked = Array.from({ length: 3 }, () => {
        let release!: () => void
        const gate = new Promise<void>(resolve => {
          release = resolve
        })
        releases.push(release)
        return async () => {
          await gate
          return fauxAssistantMessage('capped answer')
        }
      })
      const setup = await startAiAgent('lane_capped', blocked)

      for (const index of [0, 1, 2]) {
        const room = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:cap-${index}` }))
        await room.say({ id: `m-${index}`, text: `@Agent hello ${index}`, isMention: true })
      }

      await eventually(async () => {
        const conversations = await conversationsFor(setup.agentUid)
        const active = conversations.filter(
          row => !row.endedAt && row.generation.lease_id && !row.generation.cancelled_at
        )
        expect(active.length).toBe(2)
      })
      // The third room stays queued while both lanes are saturated.
      await Bun.sleep(150)
      const beforeRelease = await conversationsFor(setup.agentUid)
      expect(
        beforeRelease.filter(row => !row.endedAt && row.generation.lease_id && !row.generation.cancelled_at).length
      ).toBe(2)

      for (const release of releases) release()
      await eventually(() =>
        expect(setup.platform.outbound.filter(event => event.text === 'capped answer').length).toBe(3)
      )
    } finally {
      await appConfigService.delete(AiAgentRuntimeConfigDefinition)
    }
  })

  it('mirrors generation lifecycle into the Redis visible-output stream', async () => {
    const setup = await startAiAgent('visible_mirror', [fauxAssistantMessage('mirrored answer')])
    const dm = setup.platform.dm(setup.conversationOptions())
    await dm.say({ id: 'm1', text: 'hello' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'mirrored answer')).toBe(true))

    const [conversation] = await conversationsFor(setup.agentUid)
    const keyPrefix = `bullx-agent:external-gateway:visible-output:${encodeURIComponent(setup.agentUid)}:${encodeURIComponent(conversation!.id)}:*`
    const keys = await redis.send('KEYS', [keyPrefix])
    expect(Array.isArray(keys) && keys.length > 0).toBe(true)
    const rows = await redis.send('XRANGE', [String((keys as unknown[])[0]), '-', '+'])
    const types = (rows as Array<[string, string[]]>).flatMap(([, fields]) => {
      for (let index = 0; index < fields.length; index += 2) {
        if (String(fields[index]) === 'payload') {
          return [(JSON.parse(String(fields[index + 1])) as { type: string }).type]
        }
      }
      return []
    })
    expect(types[0]).toBe('stream.started')
    expect(types.at(-1)).toBe('stream.finished')
  })

  // Ambient wake-ups are scheduled in Redis, not held in process memory, so a worker
  // can pick up another worker's due batch. This and the next two tests fake "the
  // worker that scheduled it is gone" by seeding the conversation/message and the
  // Redis wake entry directly, then driving recovery from a freshly constructed
  // batcher / a fresh runtime binding — proving the queued ambient batch survives the
  // loss of all in-memory scheduler state.
  it('recovers due ambient batch from Redis after in-memory scheduler state is lost', async () => {
    const setup = await startAiAgent(
      'ambient_recovery',
      [fauxAssistantMessage('{"intervene":true,"reason_summary":"recover ambient"}')],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 10 }
    )
    const roomId = `${setup.adapterName}:ambient-recovery`
    const threadId = `${roomId}:thread`
    projectedRoomIds.add(roomId)
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation({
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: roomId
    })
    await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'im_ambient',
      kind: 'normal',
      content: textContent('recover from redis wake'),
      eventSource: 'test',
      eventId: 'ambient-recovery-message',
      metadata: {
        provider_refs: providerRefs({
          providerMessageId: 'ambient-recovery-message',
          providerRoomId: roomId,
          providerThreadId: threadId
        }) as JsonObject
      }
    })

    await new AiAgentAmbientBatcher().schedule({
      agentUid: setup.agentUid,
      conversationId: conversation.id,
      profile: setup.profile,
      providerRoomId: roomId,
      providerThreadId: threadId
    })
    await Bun.sleep(30)
    const intervened = await new AiAgentAmbientBatcher().drainDue(setup.profile)

    expect(intervened.some(row => row.conversationId === conversation.id && row.providerThreadId === threadId)).toBe(
      true
    )
    const turns = await llmTurnsFor(conversation.id)
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toContain('ambient_recognizer:light:light')
    const rows = await messagesFor(conversation.id)
    expect(rows.some(row => row.role === 'im_ambient' && row.kind === 'introspection')).toBe(true)
  })

  it('recovers future ambient wake from Redis during binding recovery', async () => {
    const setup = await startAiAgent(
      'ambient_recovery_future',
      [
        fauxAssistantMessage('{"intervene":true,"reason_summary":"recover future ambient"}'),
        fauxAssistantMessage('recovered ambient output')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 25 }
    )
    const roomId = `${setup.adapterName}:ambient-recovery-future`
    const threadId = `${roomId}:thread`
    projectedRoomIds.add(roomId)
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation({
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: roomId
    })
    await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'im_ambient',
      kind: 'normal',
      content: textContent('recover future redis wake'),
      eventSource: 'test',
      eventId: 'ambient-recovery-future-message',
      metadata: {
        provider_refs: providerRefs({
          providerMessageId: 'ambient-recovery-future-message',
          providerRoomId: roomId,
          providerThreadId: threadId
        }) as JsonObject
      }
    })

    await new AiAgentAmbientBatcher().schedule({
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      conversationId: conversation.id,
      profile: setup.profile,
      providerRoomId: roomId,
      providerThreadId: threadId
    })
    await setup.aiRuntime.recoverExternalGatewayBinding(setup.executionContext())

    await eventually(async () => {
      const turns = await llmTurnsFor(conversation.id)
      expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toContain('ambient_recognizer:light:light')
      expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toContain('generation:primary:primary')
    })
    await eventually(async () => {
      const rows = await messagesFor(conversation.id)
      expect(rows.some(row => row.role === 'im_ambient' && row.kind === 'introspection')).toBe(true)
      expect(
        rows.some(row => row.role === 'assistant' && textFromContent(row.content) === 'recovered ambient output')
      ).toBe(true)
    })
  })

  it('recovers may_intervene user story from real PG and Redis after runtime restart', async () => {
    const setup = await startAiAgent(
      'ambient_user_restart',
      [
        fauxAssistantMessage('{"intervene":true,"reason_summary":"deployment help requested"}'),
        fauxAssistantMessage('I can help with the deployment check.')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 500 }
    )
    const roomId = `${setup.adapterName}:ops-room`
    const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))

    expect(await redis.send('PING', [])).toBe('PONG')

    await group.say({
      authorId: 'alice',
      id: 'ambient-help-request',
      text: 'deploy is blocked; can the agent help check what failed?'
    })

    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.conversationKey).toContain(`room:${roomId}`)
      const rows = conversation ? await messagesFor(conversation.id) : []
      expect(
        rows.some(
          row => row.role === 'im_ambient' && row.kind === 'normal' && textOf(row.content).includes('deploy is blocked')
        )
      ).toBe(true)
    })
    await eventually(async () => {
      const members = await ambientRedisMembersForAgent(setup.agentUid)
      expect(members.length).toBeGreaterThan(0)
    })

    await setup.runtime.stop()
    await restartAiAgentBinding(setup)

    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'I can help with the deployment check.')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'im_ambient' && row.kind === 'introspection')).toBe(true)
    expect(
      rows.some(row => row.role === 'assistant' && textOf(row.content) === 'I can help with the deployment check.')
    ).toBe(true)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toEqual([
      'ambient_recognizer:light:light',
      'generation:primary:primary'
    ])
    await eventually(async () => {
      expect(await ambientRedisMembersForAgent(setup.agentUid)).toHaveLength(0)
    })
  })

  // The core "a second message arrives mid-run" case. While the first generation is
  // parked (its provider call awaits a blocker the test controls), a second addressed
  // message must not start its own run; it lands in generation.pending_followups,
  // and only after the first answer commits does it become the trigger of the next
  // generation. The final transcript proves strict ordering: answer, then follow-up.
  //
  // The blocker-promise idiom recurs throughout this file: a provider response that
  // awaits a Promise the test resolves on cue, so a generation can be held "in
  // flight" while later inputs are injected. The `setTimeout(release, 2_000)` lines
  // are a safety net so a missed release fails as a timeout instead of hanging.
  it('queues addressed follow-up during active generation and materializes it after the current answer', async () => {
    let releaseProvider!: () => void
    let releaseFollowupProvider!: () => void
    const providerBlocker = new Promise<void>(resolve => {
      releaseProvider = resolve
    })
    const followupProviderBlocker = new Promise<void>(resolve => {
      releaseFollowupProvider = resolve
    })
    const setup = await startAiAgent('pending_followup', [
      async () => {
        await providerBlocker
        return fauxAssistantMessage('first answer')
      },
      async () => {
        await followupProviderBlocker
        return fauxAssistantMessage('follow-up answer')
      }
    ])
    setTimeout(() => releaseProvider(), 2_000)
    setTimeout(() => releaseFollowupProvider(), 2_000)
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'start' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    await dm.say({ id: 'm2', text: 'more detail' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_followups ?? []).toHaveLength(1)
    })
    releaseProvider()

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'first answer')).toBe(true))
    const [conversation] = await conversationsFor(setup.agentUid)
    await eventually(async () => {
      const updated = (await conversationsFor(setup.agentUid))[0]!
      const rows = await messagesFor(updated.id)
      const followup = rows.find(row => row.role === 'user' && textOf(row.content) === 'more detail')
      expect(followup?.role).toBe('user')
      expect(updated.generation.trigger_message_id).toBe(followup?.id)
      expect(updated.generation.lease_id).toBeTruthy()
      expect(updated.generation.pending_followups ?? []).toHaveLength(0)
    })
    releaseFollowupProvider()
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'follow-up answer')).toBe(true))
    const rows = await messagesFor(conversation!.id)
    expect(rows.map(row => `${row.role}:${row.kind}:${textOf(row.content)}`)).toEqual([
      'user:normal:start',
      'assistant:normal:first answer',
      'user:normal:more detail',
      'assistant:normal:follow-up answer'
    ])
  })

  it('removes recalled pending follow-up without retracting the prior answer', async () => {
    let releaseProvider!: () => void
    const providerBlocker = new Promise<void>(resolve => {
      releaseProvider = resolve
    })
    const setup = await startAiAgent('pending_followup_recall', [
      async () => {
        await providerBlocker
        return fauxAssistantMessage('first answer')
      },
      fauxAssistantMessage('should not run')
    ])
    setTimeout(() => releaseProvider(), 2_000)
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'start' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    await dm.say({ id: 'm2', text: 'withdraw this detail' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_followups ?? []).toHaveLength(1)
    })
    await dm.recall('m2')
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_followups ?? []).toHaveLength(0)
    })
    releaseProvider()

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'first answer')).toBe(true))
    await Bun.sleep(120)
    expect(setup.platform.outbound.some(event => event.text === 'should not run')).toBe(false)
    expect(setup.platform.outbound.some(event => event.op === 'delete')).toBe(false)
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => textOf(row.content) === 'withdraw this detail')).toBe(false)
  })

  it('aborts a wedged provider stream via the stall watchdog and answers the queued follow-up', async () => {
    const setup = await startAiAgent(
      'stalled_stream_watchdog',
      [
        // A half-open connection: no stream events, no error — only the abort
        // signal (driven by the stall watchdog) ever ends the call.
        (_context, options) =>
          new Promise<never>((_, reject) => {
            const abort = () => reject(new Error('provider stream aborted'))
            if (options?.signal?.aborted) return abort()
            options?.signal?.addEventListener('abort', abort, { once: true })
          }),
        fauxAssistantMessage('recovered answer')
      ],
      { stallTimeoutMs: 200 }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'long question' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    await dm.say({ id: 'm2', text: 'are you stuck?' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_followups ?? []).toHaveLength(1)
    })

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'recovered answer')).toBe(true))
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'user' && textOf(row.content) === 'are you stuck?')).toBe(true)
    await eventually(async () => {
      const updated = (await conversationsFor(setup.agentUid))[0]!
      expect(updated.generation.lease_id).toBeUndefined()
      const turns = await llmTurnsFor(updated.id)
      expect(turns.filter(row => row.status === 'started')).toHaveLength(0)
    })
  })

  it('retries a stalled generation automatically and answers on the second attempt', async () => {
    const setup = await startAiAgent(
      'stall_retry',
      [
        (_context, options) =>
          new Promise<never>((_, reject) => {
            const abort = () => reject(new Error('provider stream aborted'))
            if (options?.signal?.aborted) return abort()
            options?.signal?.addEventListener('abort', abort, { once: true })
          }),
        fauxAssistantMessage('second attempt answer')
      ],
      { stallTimeoutMs: 200 }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'do the long thing' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'second attempt answer')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.some(row => row.kind === 'retry_generation' && row.status === 'succeeded')).toBe(true)
    expect(turns.filter(row => row.status === 'started')).toHaveLength(0)
    expect(conversation!.generation.lease_id).toBeUndefined()
  })

  it('retries transient provider stream errors without user involvement', async () => {
    // Two consecutive connection failures: the first is absorbed by the agent
    // loop's one-shot first-turn retry; the second surfaces to the runtime and
    // must trigger a generation-level transient retry.
    const setup = await startAiAgent('transient_retry', [
      () => {
        throw new Error('Connection error.')
      },
      () => {
        throw new Error('Connection error.')
      },
      fauxAssistantMessage('after the blip')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'hello' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'after the blip')).toBe(true))

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.some(row => row.kind === 'retry_generation' && row.status === 'succeeded')).toBe(true)
  })

  it('keeps the lease heartbeat fresh while a healthy provider stream is silent', async () => {
    const setup = await startAiAgent(
      'silent_stream_liveness',
      [
        (_context, options) =>
          new Promise<never>((_, reject) => {
            const abort = () => reject(new Error('provider stream aborted'))
            if (options?.signal?.aborted) return abort()
            options?.signal?.addEventListener('abort', abort, { once: true })
          }),
        fauxAssistantMessage('late answer')
      ],
      { stallTimeoutMs: 1_000, generationLivenessIntervalMs: 50 }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'think hard' })
    // While the stream is silent (a long reasoning stretch), the wall-clock
    // liveness beat must keep the lease unexpired so nothing takes it over.
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      const generation = conversation?.generation
      expect(generation?.lease_id).toBeTruthy()
      expect(Date.parse(generation!.heartbeat_at!)).toBeGreaterThan(Date.parse(generation!.started_at!))
      expect(Date.parse(generation!.expires_at!)).toBeGreaterThan(Date.now())
    })
    // Let the watchdog + retry settle the hung attempt so teardown is clean.
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'late answer')).toBe(true))
  })

  it('takes over an expired generation lease and materializes its queued follow-ups', async () => {
    const setup = await startAiAgent('expired_lease_takeover', [
      fauxAssistantMessage('first answer'),
      fauxAssistantMessage('takeover answer')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())
    const roomId = `${setup.adapterName}:room`

    await dm.say({ id: 'm1', text: 'start' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'first answer')).toBe(true))

    // Simulate the production failure shape: a lease whose run died without
    // unwinding (wedged provider call, then process loss), heartbeat frozen at
    // start, expiry long past, with a queued follow-up nobody will ever drain.
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    const trigger = rows.find(row => row.role === 'user')!
    const now = Date.now()
    const queuedAt = new Date(now - ms('5m')).toISOString()
    await DB.update(AiAgentConversations)
      .set({
        generation: jsonbParam({
          lease_id: 'stale-lease',
          trigger_message_id: trigger.id,
          trigger_event_id: null,
          started_at: new Date(now - ms('20m')).toISOString(),
          heartbeat_at: new Date(now - ms('20m')).toISOString(),
          expires_at: new Date(now - ms('15m')).toISOString(),
          max_expires_at: new Date(now + ms('10m')).toISOString(),
          cancelled_at: null,
          cancellation_reason: null,
          cancelled_by_event_id: null,
          streaming_card: {
            provider_message_id: 'stale-card-1',
            provider_room_id: roomId,
            provider_thread_id: `${roomId}:thread`
          },
          pending_followups: [
            {
              actor: {},
              agent_message: JSON.parse(JSON.stringify(createUserMessage('queued while wedged', now - ms('5m')))),
              created_at: queuedAt,
              event_id: 'evt-queued',
              event_source: 'mock-im',
              provider_refs: providerRefs({
                eventId: 'evt-queued',
                providerMessageId: 'm-queued',
                providerRoomId: roomId,
                providerThreadId: `${roomId}:thread`
              }),
              room: {},
              sent_at: queuedAt,
              text: 'queued while wedged'
            }
          ],
          pending_steering: []
        }),
        updatedAt: sql`now()`
      })
      .where(eq(AiAgentConversations.id, conversation!.id))

    await dm.say({ id: 'm2', text: 'hello again' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'takeover answer')).toBe(true))
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.op === 'delete' && event.messageId === 'stale-card-1')).toBe(
        true
      )
    )

    const updated = (await conversationsFor(setup.agentUid))[0]!
    expect(updated.generation.lease_id).not.toBe('stale-lease')
    const rowsAfter = await messagesFor(conversation!.id)
    const materialized = rowsAfter.find(row => row.role === 'user' && textOf(row.content) === 'queued while wedged')
    const newTrigger = rowsAfter.find(row => row.role === 'user' && textOf(row.content) === 'hello again')
    expect(materialized?.eventId).toBe('evt-queued')
    // The queued follow-up enters the transcript before the takeover trigger…
    expect(materialized!.id < newTrigger!.id).toBe(true)
    // …and the takeover generation actually saw it.
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.filter(row => row.status === 'started')).toHaveLength(0)
    const takeoverTurn = turns.at(-1)!
    expect(takeoverTurn.inputMessageIds).toContain(materialized!.id)
  })

  it('starts a new conversation on daily reset while keeping the same conversation key', async () => {
    const setup = await startAiAgent('daily_reset', [fauxAssistantMessage('old day'), fauxAssistantMessage('new day')])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'before reset' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'old day')).toBe(true))
    const [firstConversation] = await conversationsFor(setup.agentUid)
    // Backdate the conversation to a long-past day so the next message crosses the
    // daily-reset boundary and is treated as a new day, without waiting real time.
    await DB.update(AiAgentConversations)
      .set({ createdAt: new Date('2000-01-01T00:00:00.000Z'), updatedAt: sql`now()` })
      .where(eq(AiAgentConversations.id, firstConversation!.id))

    await dm.say({ id: 'm2', text: 'after reset' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'new day')).toBe(true))
    const conversations = await conversationsFor(setup.agentUid)
    expect(conversations).toHaveLength(2)
    expect(new Set(conversations.map(row => row.conversationKey)).size).toBe(1)
    expect(conversations.some(row => row.endedAt !== null)).toBe(true)
  })

  // Harder daily-reset case: the previous day's generation is still running (parked
  // provider call) when the new day's message arrives. Rolling over must end the old
  // conversation AND fence its in-flight run, so its late answer is dropped rather
  // than posted into the now-stale conversation. (The idempotent release guards
  // against the explicit release and the 2s safety timer both firing.)
  it('fences an active stale run when daily reset rolls over on the next input', async () => {
    let releaseProvider!: () => void
    let released = false
    const providerBlocker = new Promise<void>(resolve => {
      releaseProvider = () => {
        if (released) return
        released = true
        resolve()
      }
    })
    const setup = await startAiAgent('daily_reset_active', [
      async () => {
        await providerBlocker
        return fauxAssistantMessage('old late answer')
      },
      fauxAssistantMessage('new day answer')
    ])
    setTimeout(() => releaseProvider(), 2_000)
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'before reset still running' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    const [oldConversation] = await conversationsFor(setup.agentUid)
    await DB.update(AiAgentConversations)
      .set({ createdAt: new Date('2000-01-01T00:00:00.000Z'), updatedAt: sql`now()` })
      .where(eq(AiAgentConversations.id, oldConversation!.id))

    await dm.say({ id: 'm2', text: 'after reset' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'new day answer')).toBe(true))
    releaseProvider()
    await Bun.sleep(160)

    expect(setup.platform.outbound.some(event => event.text === 'old late answer')).toBe(false)
    const conversations = await conversationsFor(setup.agentUid)
    expect(conversations).toHaveLength(2)
    const old = conversations.find(row => row.id === oldConversation!.id)!
    expect(old.endedAt).toBeTruthy()
    expect(old.generation.cancelled_at).toBeTruthy()
    const oldRows = await messagesFor(old.id)
    expect(oldRows.some(row => row.role === 'assistant' && textOf(row.content) === 'old late answer')).toBe(false)
  })

  // Pins what /steer and /stop write to durable state, and — crucially — what they do
  // NOT write. The user-facing "Stopped." reply is a command acknowledgement and must
  // never enter the model transcript; steering/stop instead leave an `introspection`
  // marker the model reads. Here the active run is manufactured directly (seed a user
  // message, then acquireGenerationLease) so the commands have a live lease to act on
  // without standing up a real, parked generation — a setup several tests below reuse.
  it('persists stop and steer command semantics without putting command feedback into transcript', async () => {
    const setup = await startAiAgent('commands', [fauxAssistantMessage('steered answer')])
    const dm = setup.platform.dm(setup.conversationOptions())
    const route = {
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: dm.channelId
    }
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation(route)
    const trigger = await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'user',
      kind: 'normal',
      content: textContent('active work'),
      agentMessage: createUserMessage('active work'),
      eventSource: 'test',
      eventId: 'seed',
      metadata: {
        provider_refs: providerRefs({
          providerMessageId: 'seed',
          providerRoomId: dm.channelId,
          providerThreadId: dm.threadId
        }) as JsonObject
      }
    })
    await aiAgentConversationService.acquireGenerationLease({
      conversationId: conversation.id,
      triggerMessageId: trigger.id
    })

    await dm.say({ id: 'steer-command', text: '/steer be terse' })
    await eventually(async () => {
      const [row] = await conversationsFor(setup.agentUid)
      expect(row!.generation.pending_steering ?? []).toHaveLength(1)
    })
    await dm.say({ id: 'stop-command', text: '/stop' })
    await eventually(async () => {
      const [row] = await conversationsFor(setup.agentUid)
      expect(row!.generation.cancelled_at).toBeTruthy()
    })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'Stopped.')).toBe(true))
    const transcript = await messagesFor(conversation.id)
    expect(transcript.some(row => row.eventId === 'stop-command' && textOf(row.content) === 'Stopped.')).toBe(false)
    const stopMarker = transcript.find(row => row.eventSource === 'ai-agent.command.stop')
    expect(stopMarker?.eventId).toContain('stop-command')
    expect(stopMarker?.kind).toBe('introspection')
    expect(
      ((stopMarker?.metadata as JsonObject | undefined)?.control as JsonObject | undefined)?.command_event_id
    ).toBe(stopMarker?.eventId)
    expect(textOf(stopMarker?.content)).toContain('Treat the interrupted task as cancelled.')
    expect(textOf(stopMarker?.content)).toContain('Do not continue or resume that stopped task')

    await dm.say({ id: 'steer-fallback-command', text: '/steer answer now' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'steered answer')).toBe(true))
    const updatedTranscript = await messagesFor(conversation.id)
    expect(
      updatedTranscript.some(
        row => row.eventSource === 'ai-agent.command.steer' && textOf(row.content) === 'answer now'
      )
    ).toBe(true)
    const generationTurns = (await llmTurnsFor(conversation.id)).filter(row => row.kind === 'generation')
    expect(Number((generationTurns.at(-1)?.requestContext as JsonObject | undefined)?.tool_count)).toBeGreaterThan(0)
  })

  it('keeps tools offered on steer fallback followups (the model decides whether to use them)', async () => {
    let releaseProvider!: () => void
    const providerBlocker = new Promise<void>(resolve => {
      releaseProvider = resolve
    })
    const setup = await startAiAgent('steer_fallback_followup', [
      async () => {
        await providerBlocker
        return fauxAssistantMessage('style accepted')
      },
      fauxAssistantMessage('Bananas are usually yellow.')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'steer-command', text: '/steer answer with the conclusion first' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    await dm.say({ id: 'followup', text: 'What color are bananas usually?' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_followups ?? []).toHaveLength(1)
    })
    releaseProvider()

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'style accepted')).toBe(true))
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'Bananas are usually yellow.')).toBe(true)
    )
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    const followup = rows.find(row => row.role === 'user' && textOf(row.content) === 'What color are bananas usually?')
    expect(((followup?.metadata as JsonObject | undefined)?.control as JsonObject | undefined)?.origin).toBe(
      'followup_or_steer_fallback'
    )
    const generationTurns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    expect(Number((generationTurns.at(-1)?.requestContext as JsonObject | undefined)?.tool_count)).toBeGreaterThan(0)
  })

  it('drains active steer as a Hermes-style out-of-band note after the current answer', async () => {
    let releaseProvider!: () => void
    const providerBlocker = new Promise<void>(resolve => {
      releaseProvider = resolve
    })
    const setup = await startAiAgent('steer_drain', [
      async () => {
        await providerBlocker
        return fauxAssistantMessage('first answer')
      },
      fauxAssistantMessage('steered continuation')
    ])
    setTimeout(() => releaseProvider(), 2_000)
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'start work' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    await dm.say({ id: 'steer-command', text: '/steer focus on error handling' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_steering ?? []).toHaveLength(1)
    })
    releaseProvider()

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'first answer')).toBe(true))
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'steered continuation')).toBe(true)
    )
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    const steering = rows.find(
      row => row.eventSource === 'ai-agent.command.steer' && textOf(row.content).includes('focus on error handling')
    )
    expect(steering?.kind).toBe('introspection')
    expect(textOf(steering?.content)).toContain('<human_steering_note command_event_id="')
    expect(textOf(steering?.content)).toContain('effect="override_current_incomplete_task"')
    expect(textOf(steering?.content)).toContain('Do not continue pre-steering tool plans')
    expect(textOf(steering?.content)).toContain('focus on error handling')
  })

  // /steer issued while a tool is mid-execution must not interrupt the tool; it waits
  // for the next tool boundary, then redirects. The tool is held open (toolBlocker)
  // so the steer is guaranteed to arrive while a tool call is in flight.
  it('cuts over to pending steer at the next tool boundary', async () => {
    let releaseTool!: () => void
    const toolBlocker = new Promise<void>(resolve => {
      releaseTool = resolve
    })
    let toolStarted = false
    const slowTool = buildTool({
      name: 'slow_echo',
      label: 'Slow echo',
      description: 'Waits before echoing a value.',
      schema: z.object({ value: z.string() }),
      async execute(_toolCallId, params) {
        toolStarted = true
        await toolBlocker
        return {
          content: [{ type: 'text', text: params.value }],
          details: { value: params.value }
        }
      }
    })
    const setup = await startAiAgent(
      'steer_tool_boundary',
      [
        fauxAssistantMessage([fauxToolCall('slow_echo', { value: 'old task' })]),
        fauxAssistantMessage('steered answer')
      ],
      { tools: [slowTool] }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'start tool work' })
    await eventually(() => expect(toolStarted).toBe(true))
    await dm.say({ id: 'steer-command', text: '/steer answer in Chinese with 3 sentences' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_steering ?? []).toHaveLength(1)
    })
    releaseTool()

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'steered answer')).toBe(true))
    const [conversation] = await conversationsFor(setup.agentUid)
    expect(conversation?.generation.pending_steering ?? []).toEqual([])
    const turns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    const steeredTurnContext = turns.at(-1)?.requestContext as JsonObject | undefined
    expect(Number(steeredTurnContext?.tool_count)).toBeGreaterThan(0)
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'assistant' && textOf(row.content).includes('model did not return'))).toBe(
      false
    )
    const steering = rows.find(
      row =>
        row.eventSource === 'ai-agent.command.steer' &&
        textOf(row.content).includes('answer in Chinese with 3 sentences')
    )
    expect(steering?.kind).toBe('introspection')
    expect(textOf(steering?.content)).toContain('override_current_incomplete_task')
  })

  it('removes stale todo progress when steering cuts over at a tool boundary', async () => {
    let releaseTool!: () => void
    const toolBlocker = new Promise<void>(resolve => {
      releaseTool = resolve
    })
    let toolStarted = false
    const slowTodoTool = buildTool({
      name: 'todo',
      label: 'Todo',
      description: 'Slow test todo tool.',
      schema: z.object({
        todos: z.array(z.object({ id: z.string(), content: z.string(), status: z.string() })),
        merge: z.boolean().optional()
      }),
      async execute(_toolCallId, params) {
        toolStarted = true
        await toolBlocker
        return {
          content: [{ type: 'text', text: JSON.stringify({ todos: params.todos }) }],
          details: { todos: params.todos, summary: { total: params.todos.length } }
        }
      }
    })
    const setup = await startAiAgent(
      'steer_todo_progress_cleanup',
      [
        fauxAssistantMessage([
          fauxToolCall('todo', {
            merge: false,
            todos: [{ id: 'old', content: 'Continue the old long task', status: 'pending' }]
          })
        ]),
        fauxAssistantMessage('steered answer')
      ],
      { tools: [slowTodoTool] }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'start tool work' })
    await eventually(() => expect(toolStarted).toBe(true))
    await dm.say({ id: 'steer-command', text: '/steer answer in Chinese with 3 sentences' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_steering ?? []).toHaveLength(1)
    })
    releaseTool()

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'steered answer')).toBe(true))
    await eventually(() => {
      const visibleText = setup.platform.visibleMessages(`${setup.adapterName}:room`).map(message => message.text)
      expect(visibleText.some(text => text?.startsWith('📋 todo'))).toBe(false)
    })
  })

  it('/stop cancels the running task but still answers messages queued behind it', async () => {
    let releaseProvider!: () => void
    const providerBlocker = new Promise<void>(resolve => {
      releaseProvider = resolve
    })
    const setup = await startAiAgent('stop_resumes_followups', [
      async (_context, options) => {
        // Parked until released — and abort-aware, like a real provider call,
        // so /stop's abortAndWait settles promptly instead of timing out.
        await new Promise<void>((resolve, reject) => {
          const abort = () => reject(new Error('aborted by stop'))
          if (options?.signal?.aborted) return abort()
          options?.signal?.addEventListener('abort', abort, { once: true })
          void providerBlocker.then(resolve)
        })
        return fauxAssistantMessage('should be fenced')
      },
      fauxAssistantMessage('answer for the queued ask')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'long task' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    // Someone else's question queues behind the running task…
    await dm.say({ id: 'm2', text: 'queued question from someone else' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.pending_followups ?? []).toHaveLength(1)
    })
    // …then the task is stopped. The queued question must not evaporate.
    // (release on a timer: dm.say awaits the whole /stop handler, including
    // abortAndWait on the parked run)
    setTimeout(() => releaseProvider(), 50)
    await dm.say({ id: 'stop-command', text: '/stop' })

    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'Stopped.')).toBe(true))
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'answer for the queued ask')).toBe(true)
    )
    expect(setup.platform.outbound.some(event => event.text === 'should be fenced')).toBe(false)

    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'user' && textOf(row.content) === 'queued question from someone else')).toBe(
      true
    )
    expect(rows.some(row => row.kind === 'introspection' && textOf(row.content).includes('task_cancellation'))).toBe(
      true
    )
  })

  it('fences delayed provider output after /stop so stale answers are not sent', async () => {
    const setup = await startAiAgent('stop_fence', [
      async () => {
        await Bun.sleep(90)
        return fauxAssistantMessage('late answer')
      }
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'slow question' })
    await eventually(async () => {
      const [conversation] = await conversationsFor(setup.agentUid)
      expect(conversation?.generation.lease_id).toBeTruthy()
    })
    await dm.say({ id: 'stop-command', text: '/stop' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'Stopped.')).toBe(true))
    await Bun.sleep(160)

    expect(setup.platform.outbound.some(event => event.text === 'late answer')).toBe(false)
    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'assistant' && textOf(row.content) === 'late answer')).toBe(false)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.at(-1)?.status).toBe('cancelled')
  })

  it('does not require message edit support for /compress feedback', async () => {
    const setup = await startAiAgent('compress_unsupported', [], {
      adapterCapabilities: mockImCapabilitiesWithout('outbound', 'edit_message')
    })
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'compress-command', text: '/compress' })
    await eventually(() =>
      expect(
        setup.platform.outbound.some(event => event.text === 'Conversation already fits in the active context.')
      ).toBe(true)
    )
    expect(setup.platform.outbound.some(event => event.op === 'edit')).toBe(false)
    const [conversation] = await conversationsFor(setup.agentUid)
    expect((await messagesFor(conversation!.id)).filter(row => row.kind === 'summary')).toHaveLength(0)
    expect(await llmTurnsFor(conversation!.id)).toHaveLength(0)
  })

  it('compresses and retries when AI SDK reports provider context overflow', async () => {
    const overflow = fauxAssistantMessage('', {
      stopReason: 'error',
      errorMessage: 'Your input exceeds the context window of this model'
    })
    const setup = await startAiAgent(
      'overflow_retry',
      [
        fauxAssistantMessage('answer one'),
        fauxAssistantMessage('answer two'),
        overflow,
        fauxAssistantMessage('overflow summary'),
        fauxAssistantMessage('after overflow')
      ],
      { compressionKeepRecentTokens: 1 }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'first long input' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'answer one')).toBe(true))
    await dm.say({ id: 'm2', text: 'second long input' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'answer two')).toBe(true))
    await dm.say({ id: 'm3', text: 'overflow now' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'after overflow')).toBe(true))

    const [conversation] = await conversationsFor(setup.agentUid)
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.kind === 'summary' && textOf(row.content) === 'overflow summary')).toBe(true)
    expect(rows.some(row => row.role === 'assistant' && textOf(row.content).includes('context window'))).toBe(false)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.status}`)).toContain('overflow_retry:light:succeeded')
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.status}`)).toContain('overflow_retry:primary:succeeded')
    const leases = selectExportableGenerationLeases(turns, rows)
    const selectedTurnIds = new Set(leases.flatMap(lease => lease.turnIds))
    const failedOverflowTurn = turns.find(
      row =>
        row.kind === 'generation' && row.status === 'failed' && JSON.stringify(row.response).includes('context window')
    )
    expect(failedOverflowTurn).toBeTruthy()
    expect(selectedTurnIds.has(failedOverflowTurn!.id)).toBe(false)
    expect(leases.some(lease => lease.kind === 'overflow_retry' && lease.status === 'succeeded')).toBe(true)
  })

  it('recovers a durable generation lease after process restart', async () => {
    const setup = await startAiAgent('recovery', [fauxAssistantMessage('recovered answer')])
    const dm = setup.platform.dm(setup.conversationOptions())
    const route = {
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: dm.channelId
    }
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation(route)
    const trigger = await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'user',
      kind: 'normal',
      content: textContent('recover this'),
      agentMessage: createUserMessage('recover this'),
      eventSource: 'test',
      eventId: 'recover-message',
      metadata: {
        provider_refs: providerRefs({
          providerMessageId: 'recover-message',
          providerRoomId: dm.channelId,
          providerThreadId: dm.threadId
        }) as JsonObject
      }
    })
    await aiAgentConversationService.acquireGenerationLease({
      conversationId: conversation.id,
      triggerMessageId: trigger.id
    })

    await setup.aiRuntime.recoverExternalGatewayBinding(setup.executionContext())
    await eventually(async () => {
      await externalGatewayOutbox.dispatchPendingForBinding({
        adapter: setup.adapter,
        agent: setup.agent,
        bindingName: setup.adapterName,
        projection: externalGatewayProjectionSink,
        room: {}
      })
      expect(setup.platform.outbound.some(event => event.text === 'recovered answer')).toBe(true)
    })
    const [updated] = await conversationsFor(setup.agentUid)
    expect(updated!.generation.lease_id).toBeUndefined()
  })

  it('lease-fences pending follow-ups so a turn-boundary race never orphans a queued message', async () => {
    const setup = await startAiAgent('followup_lease_fence', [fauxAssistantMessage('unused')])
    const dm = setup.platform.dm(setup.conversationOptions())
    const route = {
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: dm.channelId
    }
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation(route)
    const followup = (eventId: string) => ({
      created_at: new Date().toISOString(),
      event_id: eventId,
      event_source: 'test',
      provider_refs: providerRefs({
        providerMessageId: eventId,
        providerRoomId: dm.channelId,
        providerThreadId: dm.threadId
      }) as JsonObject,
      text: 'queued message'
    })

    // No live lease (the previous run already committed -> generation = {}): the
    // append must refuse so the caller falls through and starts a fresh turn rather
    // than orphaning the message on a dead envelope that nothing would ever drain.
    expect(await aiAgentConversationService.appendPendingFollowup(conversation.id, followup('orphan-1'))).toBe(false)
    const [afterRefused] = await conversationsFor(setup.agentUid)
    expect((afterRefused!.generation.pending_followups ?? []) as JsonObject[]).toEqual([])

    // Active lease: the append attaches so the running generation drains it.
    const trigger = await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'user',
      kind: 'normal',
      content: textContent('first'),
      agentMessage: createUserMessage('first'),
      eventSource: 'test',
      eventId: 'fence-trigger'
    })
    const lease = await aiAgentConversationService.acquireGenerationLease({
      conversationId: conversation.id,
      triggerMessageId: trigger.id
    })
    expect(lease).toBeDefined()
    expect(await aiAgentConversationService.appendPendingFollowup(conversation.id, followup('attached-1'))).toBe(true)
    // A duplicate delivery is still "accounted for" (true) but must not add a
    // second queue entry that would collide with the committer's drain insert.
    expect(await aiAgentConversationService.appendPendingFollowup(conversation.id, followup('attached-1'))).toBe(true)
    const [withLease] = await conversationsFor(setup.agentUid)
    const queued = (withLease!.generation.pending_followups ?? []) as Array<{ event_id: string }>
    expect(queued.map(item => item.event_id)).toEqual(['attached-1'])

    // A cancelled lease (e.g. /stop landed) behaves like no lease.
    await aiAgentConversationService.cancelGeneration(conversation.id, 'stop', null, lease!.leaseId)
    expect(await aiAgentConversationService.appendPendingFollowup(conversation.id, followup('orphan-2'))).toBe(false)
  })

  it('lease-fences pending steering so a turn-boundary /steer is never orphaned', async () => {
    const setup = await startAiAgent('steer_lease_fence', [fauxAssistantMessage('unused')])
    const dm = setup.platform.dm(setup.conversationOptions())
    const route = {
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: dm.channelId
    }
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation(route)
    const steering = (commandEventId: string) => ({
      command_event_id: commandEventId,
      created_at: new Date().toISOString(),
      text: 'change direction'
    })

    // No live lease -> refuse so /steer materializes and starts a fresh turn.
    expect(await aiAgentConversationService.appendPendingSteering(conversation.id, steering('steer-orphan'))).toBe(
      false
    )

    const trigger = await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'user',
      kind: 'normal',
      content: textContent('first'),
      agentMessage: createUserMessage('first'),
      eventSource: 'test',
      eventId: 'steer-trigger'
    })
    await aiAgentConversationService.acquireGenerationLease({
      conversationId: conversation.id,
      triggerMessageId: trigger.id
    })
    expect(await aiAgentConversationService.appendPendingSteering(conversation.id, steering('steer-attached'))).toBe(
      true
    )
    const [withLease] = await conversationsFor(setup.agentUid)
    const queued = (withLease!.generation.pending_steering ?? []) as Array<{ command_event_id: string }>
    expect(queued.map(item => item.command_event_id)).toEqual(['steer-attached'])
  })

  it('recovers a lease that crashed mid-run by continuing its call_index sequence', async () => {
    const setup = await startAiAgent('recovery_midlease', [fauxAssistantMessage('recovered answer')])
    const dm = setup.platform.dm(setup.conversationOptions())
    const route = {
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: dm.channelId
    }
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation(route)
    const trigger = await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'user',
      kind: 'normal',
      content: textContent('recover this'),
      agentMessage: createUserMessage('recover this'),
      eventSource: 'test',
      eventId: 'recover-midlease',
      metadata: {
        provider_refs: providerRefs({
          providerMessageId: 'recover-midlease',
          providerRoomId: dm.channelId,
          providerThreadId: dm.threadId
        }) as JsonObject
      }
    })
    const lease = await aiAgentConversationService.acquireGenerationLease({
      conversationId: conversation.id,
      triggerMessageId: trigger.id
    })
    // The dead attempt also left a streaming card spinning in the chat.
    await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || ${jsonbParam({
          streaming_card: {
            provider_message_id: 'orphan-card-1',
            provider_room_id: dm.channelId,
            provider_thread_id: dm.threadId
          }
        })}`
      })
      .where(eq(AiAgentConversations.id, conversation.id))
    // The crashed process already recorded turns under this lease: one settled
    // call and one left open in flight (the production wedge signature).
    const turnDefaults = {
      agentUid: setup.agentUid,
      conversationId: conversation.id,
      kind: 'generation',
      profile: 'primary',
      provider: setup.profile.primaryModel.config.providerId,
      model: 'primary',
      leaseId: lease!.leaseId,
      triggerMessageId: trigger.id
    } as const
    await DB.insert(AiAgentLlmTurns).values([
      { ...turnDefaults, id: crypto.randomUUID(), status: 'succeeded', callIndex: 0, completedAt: new Date() },
      { ...turnDefaults, id: crypto.randomUUID(), status: 'started', callIndex: 1 }
    ])

    await setup.aiRuntime.recoverExternalGatewayBinding(setup.executionContext())
    await eventually(async () => {
      await externalGatewayOutbox.dispatchPendingForBinding({
        adapter: setup.adapter,
        agent: setup.agent,
        bindingName: setup.adapterName,
        projection: externalGatewayProjectionSink,
        room: {}
      })
      expect(setup.platform.outbound.some(event => event.text === 'recovered answer')).toBe(true)
      // …and the dead attempt's spinning card was deleted, not left as an orphan.
      expect(setup.platform.outbound.some(event => event.op === 'delete' && event.messageId === 'orphan-card-1')).toBe(
        true
      )
    })
    const turns = await llmTurnsFor(conversation.id)
    // The abandoned in-flight call is settled as failed, not left as phantom progress…
    expect(turns.find(row => row.callIndex === 1)?.status).toBe('failed')
    // …and the recovered run continued the lease's call_index sequence.
    const recovered = turns.filter(row => row.leaseId === lease!.leaseId && (row.callIndex ?? 0) >= 2)
    expect(recovered.length).toBeGreaterThan(0)
    expect(recovered.every(row => row.status === 'succeeded')).toBe(true)
    const [updated] = await conversationsFor(setup.agentUid)
    expect(updated!.generation.lease_id).toBeUndefined()
  })

  it('rebuilds a missing assistant final outbox row during binding recovery', async () => {
    const setup = await startAiAgent('missing_outbox_recovery', [])
    const dm = setup.platform.dm(setup.conversationOptions())
    const route = {
      agentUid: setup.agentUid,
      bindingName: setup.adapterName,
      providerRealmId: null,
      providerRoomId: dm.channelId
    }
    const conversation = await aiAgentConversationService.getOrCreateActiveConversation(route)
    const outboundKey = 'ai-agent-final:test-missing-outbox'
    await aiAgentConversationService.appendMessage({
      conversationId: conversation.id,
      role: 'assistant',
      kind: 'normal',
      content: textContent('orphaned final answer'),
      agentMessage: fauxAssistantMessage('orphaned final answer') as unknown as JsonObject,
      metadata: {
        outbound: { outbound_key: outboundKey },
        route: {
          binding_name: setup.adapterName,
          provider_thread_id: dm.threadId
        }
      }
    })

    await setup.aiRuntime.recoverExternalGatewayBinding(setup.executionContext())
    await eventually(async () => {
      await externalGatewayOutbox.dispatchPendingForBinding({
        adapter: setup.adapter,
        agent: setup.agent,
        bindingName: setup.adapterName,
        projection: externalGatewayProjectionSink,
        room: {}
      })
      expect(setup.platform.outbound.some(event => event.text === 'orphaned final answer')).toBe(true)
    })
    const [row] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(eq(ExternalGatewayOutbox.agentUid, setup.agentUid), eq(ExternalGatewayOutbox.outboundKey, outboundKey))
      )
      .limit(1)
    expect(row?.status).toBe('sent')
  })

  it('clarify ends the turn; the user reply starts the next turn', async () => {
    const clarifyRegistry = new AiAgentClarifyRegistry()
    const setup = await startAiAgent(
      'clarify_reply',
      [
        fauxAssistantMessage([fauxToolCall('clarify', { question: 'A or B?', choices: ['A', 'B'] })]),
        fauxAssistantMessage('you picked A')
      ],
      { enableClarify: true, clarifyTimeoutMs: 5_000, clarifyRegistry }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent help' })
    await eventually(() =>
      expect(
        setup.platform.outbound
          .filter(event => event.op === 'post')
          .map(event => event.text)
          .join('\n')
      ).toContain('A or B?')
    )
    const [conversation] = await conversationsFor(setup.agentUid)
    await eventually(() => expect(clarifyRegistry.has(conversation!.id)).toBe(true))
    // The ask ended the IM turn: the generation committed and released its
    // lease; nothing waits in-process for the answer.
    await eventually(async () => {
      const [refreshed] = await conversationsFor(setup.agentUid)
      expect(refreshed!.generation.lease_id).toBeUndefined()
    })
    expect(setup.platform.outbound.filter(event => event.op === 'post' && event.text === 'you picked A')).toHaveLength(
      0
    )

    await dm.say({ id: 'm2', text: '1' })
    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.op === 'post').map(event => event.text)).toContain(
        'you picked A'
      )
    )
    expect(clarifyRegistry.has(conversation!.id)).toBe(false)

    const rows = await messagesFor(conversation!.id)
    // The reply is a normal transcript message: turn = one IM Q&A exchange.
    expect(rows.some(row => row.role === 'user' && textOf(row.content) === '1')).toBe(true)

    const turns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    expect(turns).toHaveLength(2)
    const askTurn = turns[0]!
    const answerTurn = turns[1]!
    // Two separate turns under two separate leases, each a fresh call sequence.
    expect(turns.map(row => row.callIndex)).toEqual([0, 0])
    expect(askTurn.leaseId).not.toBe(answerTurn.leaseId)
    expect(turns.every(row => row.status === 'succeeded')).toBe(true)

    const toolCallBlocks = jsonObjects((askTurn.response as JsonObject).content)
    expect(toolCallBlocks.some(block => block.type === 'toolCall' && toolNameFromJson(block) === 'clarify')).toBe(true)
    const toolResults = jsonObjects(askTurn.toolResults)
    expect(toolResults.some(result => result.role === 'toolResult' && toolNameFromJson(result) === 'clarify')).toBe(
      true
    )

    // The answer turn re-renders the ask turn (assistant + clarify tool result)
    // plus the user's reply from the transcript.
    const trajectory = reconstructLlmTurnTrajectory({ turns, messages: rows })
    const secondCall = trajectory[1]!
    expect(secondCall.request.exactLlmRequest).toBe(true)
    expect(secondCall.request.messages.map(message => message.role)).toEqual([
      'user',
      'assistant',
      'toolResult',
      'user'
    ])
    expect(JSON.stringify(secondCall.request.messages.at(-1))).toContain('1')
    expect(secondCall.request.tools.some(tool => jsonRecord(tool)?.name === 'clarify')).toBe(true)
  })

  it('an unanswered clarify expires its gate; a later reply still starts the next turn', async () => {
    const clarifyRegistry = new AiAgentClarifyRegistry()
    const setup = await startAiAgent(
      'clarify_timeout',
      [
        fauxAssistantMessage([fauxToolCall('clarify', { question: 'still there?' })]),
        fauxAssistantMessage('moving on')
      ],
      { enableClarify: true, clarifyTimeoutMs: 80, clarifyRegistry }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent help' })
    const [conversation] = await eventually(async () => {
      const conversations = await conversationsFor(setup.agentUid)
      expect(clarifyRegistry.has(conversations[0]!.id)).toBe(true)
      return conversations
    })
    // The gate (card lock + group reply upgrade) expires; the turn stays over.
    await eventually(() => expect(clarifyRegistry.has(conversation!.id)).toBe(false))
    // A late reply is still just the next inbound message.
    await dm.say({ id: 'm2', text: 'sorry, here now' })
    await eventually(() =>
      expect(setup.platform.outbound.filter(event => event.op === 'post').map(event => event.text)).toContain(
        'moving on'
      )
    )
  })

  it('records prepared tool execution arguments in the LLM turn tool result', async () => {
    const preparedTool = buildTool({
      name: 'prepared_echo',
      label: 'Prepared echo',
      description: 'Echoes a normalized value.',
      schema: z.object({ value: z.string() }),
      prepareArguments(args) {
        const input = typeof args === 'object' && args !== null && 'raw' in args ? (args as { raw?: unknown }).raw : ''
        return { value: String(input).trim().toUpperCase() }
      },
      async execute(_toolCallId, params) {
        return {
          content: [{ type: 'text', text: params.value }],
          details: { seen: params.value }
        }
      }
    })
    const setup = await startAiAgent(
      'prepared_tool_args',
      [
        fauxAssistantMessage([fauxToolCall('prepared_echo', { raw: '  abc  ' })]),
        fauxAssistantMessage('prepared done')
      ],
      { tools: [preparedTool] }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent use tool' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'prepared done')).toBe(true))

    const [conversation] = await conversationsFor(setup.agentUid)
    const [toolCallTurn] = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    const [toolResult] = jsonObjects(toolCallTurn!.toolResults)
    const details = jsonRecord(toolResult?.details)
    const execution = jsonRecord(details?.bullx_execution)
    expect(details?.seen).toBe('ABC')
    expect(execution?.arguments).toEqual({ value: 'ABC' })
    expect(execution?.raw_arguments).toEqual({ raw: '  abc  ' })
    expect(execution?.llm_turn_id).toBe(toolCallTurn!.id)
    expect(execution?.idempotency_key).toBe(`llm-turn:${toolCallTurn!.id}:tool-call:${toolResult?.toolCallId}`)
  })

  it('continues after a visible planning message that only writes active todos', async () => {
    const setup = await startAiAgent('todo_planning_continue', [
      fauxAssistantMessage([
        { type: 'text', text: 'I will make a plan first.' },
        fauxToolCall('todo', {
          todos: [
            { id: 'inspect', content: 'Inspect migration files', status: 'in_progress' },
            { id: 'pr', content: 'Open the pull request', status: 'pending' }
          ]
        })
      ]),
      fauxAssistantMessage('final answer after plan')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent migrate the repo' })
    await eventually(() =>
      expect(
        setup.platform.outbound.some(event => event.op === 'post' && event.text === 'final answer after plan')
      ).toBe(true)
    )
    expect(
      setup.platform.outbound.some(event => event.op === 'post' && event.text === 'I will make a plan first.')
    ).toBe(false)

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    expect(turns).toHaveLength(2)
    expect(turns.map(row => row.callIndex)).toEqual([0, 1])
  })

  // check_back_later lets the agent park work and revisit it on a schedule. The
  // re-check runs in its OWN conversation (isolated from the source thread), but its
  // visible answer must route back to the original room/thread the user asked in.
  // `at` is set in the past so the scheduler fires the wakeup immediately.
  it('schedules check_back_later as a one-shot isolated wakeup and routes visible output back to source', async () => {
    const setup = await startAiAgent('check_back_later', [
      fauxAssistantMessage([
        fauxToolCall('check_back_later', {
          at: new Date(Date.now() - 1_000).toISOString(),
          reason: 'approval is still pending',
          check: 'Check whether the approval finished.',
          context_summary: 'The account signup was submitted and is waiting for review.'
        })
      ]),
      fauxAssistantMessage('I will check again later.'),
      fauxAssistantMessage('The approval is still pending.')
    ])
    const roomId = `${setup.adapterName}:checkback-room`
    const threadId = `${roomId}:thread`
    const group = setup.platform.group(setup.conversationOptions({ channelId: roomId, threadId }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent submit approval status check' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'I will check again later.')).toBe(true)
    )

    const [sourceConversation] = await conversationsFor(setup.agentUid)
    const [pendingCheckback] = await DB.select()
      .from(AiAgentCheckbacks)
      .where(eq(AiAgentCheckbacks.agentUid, setup.agentUid))
      .limit(1)

    expect(pendingCheckback?.status).toBe('pending')
    expect(pendingCheckback?.timezone).toBeTruthy()
    expect(pendingCheckback?.source.provider_room_id).toBe(roomId)
    expect(pendingCheckback?.source.provider_thread_id).toBe(threadId)

    const scheduler = new SchedulerRuntime()
    scheduler.setAgentExecutor(setup.aiRuntime)
    try {
      await scheduler.start()
      await eventually(async () => {
        const [completed] = await DB.select()
          .from(AiAgentCheckbacks)
          .where(eq(AiAgentCheckbacks.id, pendingCheckback!.id))
          .limit(1)
        expect(completed?.status).toBe('succeeded')
        expect(completed?.conversationId).toBeTruthy()
      })
    } finally {
      await scheduler.stop()
    }

    const [completedCheckback] = await DB.select()
      .from(AiAgentCheckbacks)
      .where(eq(AiAgentCheckbacks.id, pendingCheckback!.id))
      .limit(1)
    expect(completedCheckback?.conversationId).not.toBe(sourceConversation!.id)

    await externalGatewayOutbox.dispatchPendingForBinding({
      adapter: setup.adapter,
      agent: setup.agent,
      bindingName: setup.adapterName,
      projection: externalGatewayProjectionSink,
      room: {}
    })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'The approval is still pending.')).toBe(true)
    )
    const routedOutputCount = () =>
      setup.platform.outbound.filter(event => event.text === 'The approval is still pending.').length

    const checkbackMessages = await messagesFor(completedCheckback!.conversationId!)
    expect(checkbackMessages.map(row => `${row.role}:${row.kind}`)).toEqual(['user:normal', 'assistant:normal'])
    expect(checkbackMessages[0]?.eventSource).toBe('ai-agent.check_back_later')

    const checkbackTurns = await llmTurnsFor(completedCheckback!.conversationId!)
    expect(checkbackTurns.map(row => row.kind)).toEqual(['checkback_generation'])

    // Force the checkback back into a stale `running` claim (lease already expired) to
    // mimic a worker that ran it but died before marking it done. A second scheduler
    // must reclaim and finish it without re-running the work — the idempotency check
    // below asserts exactly one routed output, one conversation, one turn.
    await DB.update(AiAgentCheckbacks)
      .set({
        status: 'running',
        claimedBy: null,
        claimedAt: null,
        leaseExpiresAt: new Date(Date.now() - 1_000),
        completedAt: null,
        updatedAt: sql`now()`
      })
      .where(eq(AiAgentCheckbacks.id, pendingCheckback!.id))

    const retryScheduler = new SchedulerRuntime()
    retryScheduler.setAgentExecutor(setup.aiRuntime)
    try {
      await retryScheduler.start()
      await eventually(async () => {
        const [completed] = await DB.select()
          .from(AiAgentCheckbacks)
          .where(eq(AiAgentCheckbacks.id, pendingCheckback!.id))
          .limit(1)
        expect(completed?.status).toBe('succeeded')
      })
    } finally {
      await retryScheduler.stop()
    }

    await externalGatewayOutbox.dispatchPendingForBinding({
      adapter: setup.adapter,
      agent: setup.agent,
      bindingName: setup.adapterName,
      projection: externalGatewayProjectionSink,
      room: {}
    })
    expect(routedOutputCount()).toBe(1)
    expect(await messagesFor(completedCheckback!.conversationId!)).toHaveLength(2)
    expect(await llmTurnsFor(completedCheckback!.conversationId!)).toHaveLength(1)
  })

  it('exposes todo by default, shows compact editable progress, and hydrates active todos later', async () => {
    const setup = await startAiAgent('todo_default_hydrate', [
      fauxAssistantMessage([
        fauxToolCall('todo', {
          todos: [
            { id: '1', content: 'Inspect repo', status: 'pending' },
            { id: '2', content: 'Already done', status: 'completed' }
          ]
        })
      ]),
      fauxAssistantMessage('plan ready'),
      fauxAssistantMessage('continuing from active plan')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent plan this' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'plan ready')).toBe(true))

    expect(
      setup.platform.outbound.some(event => event.op === 'post' && event.text === '📋 todo: "planning 2 task(s)"')
    ).toBe(true)
    expect(setup.platform.outbound.some(event => event.op === 'edit' && event.text === '📋 plan 1/2 task(s)')).toBe(
      true
    )
    expect(setup.platform.outbound.some(event => event.text?.includes('"todos"'))).toBe(false)

    const [conversation] = await conversationsFor(setup.agentUid)
    const firstTurns = await llmTurnsFor(conversation!.id)
    const firstToolDefinitions = jsonObjects(firstTurns[0]?.requestPatches).flatMap(patch =>
      patch.type === 'llm_tool_definitions' ? jsonObjects(patch.tools) : []
    )
    expect(firstToolDefinitions.some(tool => tool.name === 'todo')).toBe(true)

    await dm.say({ id: 'm2', text: '@Agent what is still active?' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'continuing from active plan')).toBe(true)
    )

    const turns = await llmTurnsFor(conversation!.id)
    const trajectory = reconstructLlmTurnTrajectory({
      turns,
      messages: await messagesFor(conversation!.id)
    })
    const lastRequestText = trajectory
      .at(-1)!
      .request.messages.flatMap(message =>
        jsonObjects(message.content).flatMap(block => (typeof block.text === 'string' ? [block.text] : []))
      )
      .join('\n')
    expect(lastRequestText).toContain('[Your active task list was preserved for this conversation]')
    expect(lastRequestText).toContain('Inspect repo')
    expect(lastRequestText).not.toContain('Already done')
  })

  it('edits one todo progress message across repeated todo calls in a run', async () => {
    const setup = await startAiAgent('todo_progress_dedupe', [
      fauxAssistantMessage([
        fauxToolCall('todo', {
          todos: [
            { id: '1', content: 'Inspect repo', status: 'pending' },
            { id: '2', content: 'Push branch', status: 'pending' }
          ]
        })
      ]),
      fauxAssistantMessage([
        fauxToolCall('todo', {
          todos: [
            { id: '1', content: 'Inspect repo', status: 'completed' },
            { id: '2', content: 'Push branch', status: 'pending' }
          ]
        })
      ]),
      fauxAssistantMessage('plan ready')
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent plan this' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'plan ready')).toBe(true))

    const todoPosts = setup.platform.outbound.filter(event => event.op === 'post' && event.text?.startsWith('📋 todo:'))
    const todoEdits = setup.platform.outbound.filter(event => event.op === 'edit' && event.text?.startsWith('📋'))
    expect(todoPosts).toHaveLength(1)
    expect(todoEdits.length).toBeGreaterThanOrEqual(2)
  })

  it('routes todo progress into the active streaming card status area', async () => {
    const setup = await startAiAgent(
      'todo_progress_streaming_card',
      [
        fauxAssistantMessage([
          fauxToolCall('todo', {
            todos: [
              { id: '1', content: 'Inspect repo', status: 'pending' },
              { id: '2', content: 'Push branch', status: 'pending' }
            ]
          })
        ]),
        fauxAssistantMessage('plan ready')
      ],
      { enableStreaming: true }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent plan this' })
    await eventually(() => expect(setup.platform.streamingCards).toHaveLength(1))
    const card = setup.platform.streamingCards[0]!
    await eventually(() => expect(card.statusUpdates).toContain('📋 todo: "planning 2 task(s)"'))
    await eventually(() => expect(card.statusUpdates).toContain('📋 plan 2 task(s)'))
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'plan ready')).toBe(true))

    expect(setup.platform.outbound.some(event => event.text?.includes('📋'))).toBe(false)
    expect(card.finalText).toBe('plan ready')
  })

  it('drops todo progress on non-editable IM surfaces', async () => {
    const setup = await startAiAgent(
      'todo_no_progress',
      [
        fauxAssistantMessage([
          fauxToolCall('todo', {
            todos: [{ id: '1', content: 'Plan quietly', status: 'pending' }]
          })
        ]),
        fauxAssistantMessage('quiet done')
      ],
      { adapterCapabilities: mockImCapabilitiesWithout('outbound', 'edit_message') }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent plan quietly' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'quiet done')).toBe(true))

    expect(setup.platform.outbound.some(event => event.text?.includes('📋'))).toBe(false)
    expect(setup.platform.outbound.some(event => event.text?.includes('"todos"'))).toBe(false)
  })

  it('uses assistant text as the final answer when todo is only housekeeping', async () => {
    const setup = await startAiAgent('todo_housekeeping_text', [
      fauxAssistantMessage([
        { type: 'text', text: 'I will track this and start now.' },
        fauxToolCall('todo', {
          todos: [{ id: '1', content: 'Start now', status: 'in_progress' }]
        })
      ])
    ])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent do it' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'I will track this and start now.')).toBe(true)
    )

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    expect(turns).toHaveLength(1)
    expect(setup.platform.outbound.filter(event => event.text === 'I will track this and start now.')).toHaveLength(1)
  })

  it('clarify card button resolves the run, and a second click is a no-op (first interaction wins)', async () => {
    const clarifyRegistry = new AiAgentClarifyRegistry()
    const setup = await startAiAgent(
      'clarify_card',
      [
        fauxAssistantMessage([fauxToolCall('clarify', { question: 'A or B?', choices: ['A', 'B'] })]),
        fauxAssistantMessage('you picked A')
      ],
      { enableClarify: true, clarifyTimeoutMs: 5_000, clarifyRegistry }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent help' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text?.includes('A or B?'))).toBe(true))
    const [conversation] = await conversationsFor(setup.agentUid)
    await eventually(() => expect(clarifyRegistry.has(conversation!.id)).toBe(true))

    const cardPost = setup.platform.outbound.find(event => event.messageId && event.text?.includes('A or B?'))
    const messageId = cardPost!.messageId!
    const value = JSON.stringify({
      version: 'bullx.interactive_output.action.v1',
      interactionId: conversation!.id,
      controlId: 'clarify_answer',
      optionId: 'choice_0',
      value: 'A'
    })

    await dm.clickButton({ messageId, value })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'you picked A')).toBe(true))
    expect(clarifyRegistry.has(conversation!.id)).toBe(false)
    // the original card is edited to its locked state
    await eventually(() => expect(setup.platform.outbound.some(event => event.op === 'edit')).toBe(true))

    const before = setup.platform.outbound.length
    await dm.clickButton({ messageId, value })
    await Bun.sleep(60)
    expect(setup.platform.outbound.length).toBe(before)
  })

  it('group non-@mention reply answers a pending clarify via the room gate', async () => {
    const clarifyRegistry = new AiAgentClarifyRegistry()
    const setup = await startAiAgent(
      'clarify_group_gate',
      [
        fauxAssistantMessage([fauxToolCall('clarify', { question: 'pick X or Y?', choices: ['X', 'Y'] })]),
        fauxAssistantMessage('got it')
      ],
      {
        enableClarify: true,
        clarifyTimeoutMs: 5_000,
        clarifyRegistry,
        groupMessageMode: 'observe_all'
      }
    )
    const group = setup.platform.group(setup.conversationOptions())

    await group.say({ id: 'g1', text: '@Agent help', isMention: true })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text?.includes('pick X or Y?'))).toBe(true)
    )
    const [conversation] = await conversationsFor(setup.agentUid)
    await eventually(() => expect(clarifyRegistry.has(conversation!.id)).toBe(true))

    // A non-@mention group reply is normally observed-and-dropped; the pending-clarify
    // gate upgrades it to addressed so it reaches the text-intercept.
    await group.say({ id: 'g2', text: 'Y', isMention: false })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'got it')).toBe(true))
    expect(clarifyRegistry.has(conversation!.id)).toBe(false)
    // gate closed: a further non-@mention message no longer wakes a generation
    const before = setup.platform.outbound.length
    await group.say({ id: 'g3', text: 'unrelated chatter', isMention: false })
    await Bun.sleep(60)
    expect(setup.platform.outbound.length).toBe(before)
  })

  it('streams the answer into a CardKit card and records it as sent without a duplicate post', async () => {
    const setup = await startAiAgent('streaming_card', [fauxAssistantMessage('hello world')], { enableStreaming: true })
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent hi' })
    await eventually(() => expect(setup.platform.streamingCards).toHaveLength(1))
    const card = setup.platform.streamingCards[0]!
    await eventually(() => expect(card.finalStatus).toBe('completed'))
    expect(card.finalText).toBe('hello world')
    expect(card.updates.length).toBeGreaterThan(0)

    // The card/sent outbox row is written during commit, which runs after finish();
    // wait for it rather than racing the commit.
    await eventually(async () => {
      const cardRows = await DB.select()
        .from(ExternalGatewayOutbox)
        .where(
          and(
            eq(ExternalGatewayOutbox.agentUid, setup.agentUid),
            eq(ExternalGatewayOutbox.operation, 'card'),
            eq(ExternalGatewayOutbox.status, 'sent')
          )
        )
      expect(cardRows.some(row => row.providerMessageId === card.messageId)).toBe(true)
    })
    // no duplicate plain post of the same answer
    expect(setup.platform.outbound.some(event => event.op === 'post' && event.text === 'hello world')).toBe(false)

    await eventually(async () => {
      const [projected] = await DB.select()
        .from(ExternalMessages)
        .where(and(eq(ExternalMessages.roomId, dm.channelId), eq(ExternalMessages.messageId, card.messageId)))
      expect(projected).toMatchObject({
        authorId: 'self',
        text: 'hello world',
        roomId: dm.channelId,
        messageId: card.messageId
      })
    })
  })

  it('falls back to a normal post when a streaming card cannot confirm the final text', async () => {
    const setup = await startAiAgent('streaming_card_unconfirmed', [fauxAssistantMessage('final answer')], {
      enableStreaming: true
    })
    // Wrap the adapter so the card reports delivered-but-not-confirmed: the platform
    // accepted the card yet could not verify the final text actually rendered. The
    // runtime must then post the answer as a plain message so it is never silently
    // lost behind a card that may be blank.
    const originalBeginStreamingCard = setup.adapter.beginStreamingCard!.bind(setup.adapter)
    setup.adapter.beginStreamingCard = async input => {
      const handle = await originalBeginStreamingCard(input)
      return {
        ...handle,
        finish: async (finalText, status) => {
          await handle.finish(finalText, status)
          return { delivered: true, finalTextConfirmed: false, fallbackReason: 'test_unconfirmed' }
        }
      }
    }
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent hi' })
    await eventually(() => expect(setup.platform.streamingCards).toHaveLength(1))
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.op === 'post' && event.text === 'final answer')).toBe(true)
    )

    const cardRows = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, setup.agentUid),
          eq(ExternalGatewayOutbox.operation, 'card'),
          eq(ExternalGatewayOutbox.status, 'sent')
        )
      )
    expect(cardRows).toHaveLength(0)
  })

  it('opens the streaming card during the tool phase, before the first answer token', async () => {
    let releaseTool!: () => void
    const toolBlocker = new Promise<void>(resolve => {
      releaseTool = resolve
    })
    let toolStarted = false
    const slowTool = buildTool({
      name: 'slow_lookup',
      label: 'Slow lookup',
      description: 'Waits before returning a value.',
      schema: z.object({ query: z.string() }),
      async execute(_toolCallId, params) {
        toolStarted = true
        await toolBlocker
        return {
          content: [{ type: 'text', text: 'lookup data' }],
          details: { query: params.query }
        }
      }
    })
    const setup = await startAiAgent(
      'streaming_card_eager',
      [
        fauxAssistantMessage([fauxToolCall('slow_lookup', { query: 'stock price' })]),
        fauxAssistantMessage('final answer')
      ],
      { enableStreaming: true, tools: [slowTool] }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent check the stock price' })
    await eventually(() => expect(toolStarted).toBe(true))
    // Tool still blocked, no answer text streamed yet — the card is already open.
    await eventually(() => expect(setup.platform.streamingCards).toHaveLength(1))
    const card = setup.platform.streamingCards[0]!
    expect(card.finalStatus).toBeUndefined()

    releaseTool()
    await eventually(() => expect(card.finalStatus).toBe('completed'))
    expect(card.finalText).toBe('final answer')
    expect(setup.platform.outbound.some(event => event.op === 'post' && event.text === 'final answer')).toBe(false)
  })

  it('finishes failed streaming cards with a user-facing error instead of partial model text', async () => {
    const setup = await startAiAgent(
      'streaming_card_error',
      [
        fauxAssistantMessage('I will continue searching before answering.', {
          errorMessage: 'Upstream idle timeout exceeded',
          stopReason: 'error'
        })
      ],
      { enableStreaming: true }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent search then answer' })
    await eventually(() => expect(setup.platform.streamingCards).toHaveLength(1))
    const card = setup.platform.streamingCards[0]!
    await eventually(() => expect(card.finalStatus).toBe('failed'))
    expect(card.finalText).toBe('模型请求超时，请稍后重试。')
    expect(card.finalText).not.toContain('continue searching')
  })

  it('summarizes internal database errors in streaming cards without exposing raw SQL', async () => {
    const setup = await startAiAgent(
      'streaming_card_internal_error',
      [
        fauxAssistantMessage('', {
          errorMessage:
            'Failed query: insert into "ai_agent_llm_turns" ("id", "agent_uid", "conversation_id") values (...)' +
            '\nCaused by: duplicate key value violates unique constraint' +
            '\nconstraint: ai_agent_llm_turns_lease_call_index',
          stopReason: 'error'
        })
      ],
      { enableStreaming: true }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent run' })
    await eventually(() => expect(setup.platform.streamingCards).toHaveLength(1))
    const card = setup.platform.streamingCards[0]!
    await eventually(() => expect(card.finalStatus).toBe('failed'))
    expect(card.finalText).toBe('内部运行错误：数据库写入失败。详细错误已记录，请查看服务日志。')
    expect(card.finalText).not.toContain('insert into')
    expect(card.finalText).not.toContain('ai_agent_llm_turns')
  })

  it('falls back to a single post when the adapter does not support streaming', async () => {
    const setup = await startAiAgent('streaming_disabled', [fauxAssistantMessage('plain answer')], {
      enableStreaming: false
    })
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent hi' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.op === 'post' && event.text === 'plain answer')).toBe(true)
    )
    expect(setup.platform.streamingCards).toHaveLength(0)
  })
})

/**
 * Stands up one fully wired agent for a single test and returns handles to drive it.
 *
 * It glues together the three fakes the whole file leans on:
 * - a fake IM platform/adapter (`platform`) that delivers inbound messages and
 *   records everything the agent posts back in `platform.outbound`;
 * - a fake LLM provider seeded with `responses` — the scripted model replies the run
 *   will consume in order (each may be a static message or a function that blocks /
 *   inspects the abort signal, used to park or fail a generation on cue);
 * - a real `AiAgentRuntime` + `ExternalGatewayRuntime` against the real Postgres and
 *   Redis, so lease/recovery/audit behavior is exercised for real, not mocked.
 *
 * The returned object exposes `conversationOptions` (a room/thread builder that also
 * registers the room for cleanup), `executionContext` (for directly invoking binding
 * recovery), and the underlying `profile`, `adapter`, `aiRuntime`, and `runtime`.
 *
 * @param name - short label; namespaces the agent uid, adapter, and provider so
 *   parallel tests never collide and cleanup can target exactly this test's rows.
 * @param responses - scripted model turns, consumed in order by the fake provider.
 */
async function startAiAgent(
  name: string,
  responses: FauxResponseStep[],
  options: {
    adapterCapabilities?: ExternalGatewayAdapterCapabilities
    addressedMediaBatchWindowMs?: number
    ambientBatchWindowMs?: number
    compressionKeepRecentTokens?: number
    groupMessageMode?: 'observe_all' | 'may_intervene'
    clarifyTimeoutMs?: number
    stallTimeoutMs?: number
    streamGapTimeoutMs?: number
    maxTransientRetries?: number
    generationLivenessIntervalMs?: number
    enableChatRecall?: boolean
    enableClarify?: boolean
    enableStreaming?: boolean
    clarifyRegistry?: AiAgentClarifyRegistry
    tools?: AgentTool<any>[]
    activeToolNames?: string[]
  } = {}
) {
  const platform: MockImPlatformInstance = new MockImPlatformCtor()
  const adapterName = `mock_${name}_${Math.random().toString(36).slice(2)}`
  const factoryId = `${testPrefix}_${name}_factory`
  const agentUid = `${testPrefix}_${name}`.toLowerCase()
  agentUids.add(agentUid)

  const registration = registerFauxProvider({
    provider: `${testPrefix}_${name}_provider`,
    models: [
      { id: 'primary', contextWindow: 65_536 },
      { id: 'light', contextWindow: 65_536 },
      { id: 'heavy', contextWindow: 65_536 }
    ]
  })
  registration.setResponses(responses)
  fauxRegistrations.add(registration)

  registerExternalGatewayAdapterFactory({
    id: factoryId,
    create: context =>
      platform.createAdapter(context.channel.name, {
        capabilities: options.adapterCapabilities ?? fullMockImCapabilities,
        groupMessageMode: options.groupMessageMode ?? 'observe_all',
        enableStreaming: options.enableStreaming
      })
  })

  const agent = await createAgent({
    uid: agentUid,
    metadata: {
      external: {
        adapters: [{ adapter: factoryId, name: adapterName }]
      }
    }
  })
  const profile = runtimeProfile(registration, options)
  const aiRuntime = new AiAgentRuntime({
    addressedMediaBatchWindowMs: options.addressedMediaBatchWindowMs,
    loadProfile: async () => profile,
    clarifyTimeoutMs: options.clarifyTimeoutMs,
    generationLivenessIntervalMs: options.generationLivenessIntervalMs,
    clarify: options.clarifyRegistry
  })
  const computerFiles = new Map<string, Buffer>()
  aiRuntime.setComputerFileReader(async (_agentUid, path) => computerFiles.get(posix.normalize(path)) ?? null)
  if (options.tools) aiRuntime.setTools(options.tools, options.activeToolNames ?? options.tools.map(tool => tool.name))
  if (options.enableChatRecall) aiRuntime.setChatRecallEnabled(true)
  if (options.enableClarify) aiRuntime.setClarifyEnabled(true)
  const runtime = new ExternalGatewayRuntime()
  runtimes.add(runtime)
  await runtime.start({
    agentExecutor: aiRuntime,
    getComputerFileWriter: async () => ({
      writeFiles: async (files, opts = {}) => {
        for (const file of files) {
          const path = normalizeComputerPath(file.path, opts.cwd ?? '/workspace')
          computerFiles.set(path, await computerFileContentBuffer(file.content))
        }
      }
    }),
    getChannelConfig: async () => ({ group_message_mode: options.groupMessageMode ?? 'observe_all' }),
    loadActiveAgents: async () => [agent]
  })
  const adapter = platform.adapters.get(adapterName)!

  return {
    adapter,
    adapterName,
    agent,
    agentUid,
    aiRuntime,
    conversationOptions(overrides: Partial<MockImConversationOptions> = {}): MockImConversationOptions {
      const channelId = overrides.channelId ?? `${adapterName}:room`
      projectedRoomIds.add(channelId)
      return {
        adapterName,
        agentUid,
        channelId,
        channelName: adapterName,
        deliver: runtime.handleWebhook.bind(runtime),
        mode: options.groupMessageMode ?? 'observe_all',
        threadId: overrides.threadId ?? `${channelId}:thread`,
        ...overrides
      }
    },
    executionContext: () => ({
      adapter,
      agent,
      agentUid,
      bindingName: adapterName,
      outbox: externalGatewayOutbox,
      projection: externalGatewayProjectionSink,
      scheduleOutboxDrain: () => undefined
    }),
    platform,
    profile,
    runtime
  }
}

function normalizeComputerPath(path: string, cwd: string): string {
  return posix.normalize(path.startsWith('/') ? path : `${cwd.replace(/\/+$/u, '')}/${path}`)
}

async function computerFileContentBuffer(content: ComputerFile['content']): Promise<Buffer> {
  if (typeof content === 'string') return Buffer.from(content)
  if (content instanceof Blob) return Buffer.from(await content.arrayBuffer())
  return Buffer.from(content)
}

/**
 * Simulates a process restart: brings up a brand-new runtime + binding on the same
 * agent and platform, with no carried-over in-memory state. Used by recovery tests to
 * prove that durable PG/Redis state alone is enough to resume the agent's work.
 */
async function restartAiAgentBinding(setup: Awaited<ReturnType<typeof startAiAgent>>): Promise<void> {
  const aiRuntime = new AiAgentRuntime({
    loadProfile: async () => setup.profile
  })
  const runtime = new ExternalGatewayRuntime()
  runtimes.add(runtime)
  await runtime.start({
    agentExecutor: aiRuntime,
    getChannelConfig: async () => ({ group_message_mode: 'may_intervene' }),
    loadActiveAgents: async () => [setup.agent]
  })
}

/**
 * Builds the runtime profile (model tiers, timeouts, compression/ambient knobs) all
 * tests run against. The three tiers — primary / light / heavy — are what assertions
 * like "recognizer ran on `light`, generation on `primary`" key off. Most timeouts
 * default high so they never fire by accident; a test that exercises a timeout passes
 * a tiny override (e.g. `stallTimeoutMs`, `ambientBatchWindowMs`) to trigger it fast.
 */
function runtimeProfile(
  registration: FauxProviderRegistration,
  options: {
    ambientBatchWindowMs?: number
    compressionKeepRecentTokens?: number
    stallTimeoutMs?: number
    streamGapTimeoutMs?: number
    maxTransientRetries?: number
  }
): AiAgentRuntimeProfile {
  const primary = registration.getModel('primary')!
  const light = registration.getModel('light')!
  const heavy = registration.getModel('heavy')!
  return {
    ambient: {
      batchWindowMs: options.ambientBatchWindowMs ?? 20,
      hardCapMs: 5_000
    },
    parallelism: {
      maxConversationsPerAgent: 16
    },
    generation: {
      maxTurns: 100,
      stallTimeoutMs: options.stallTimeoutMs ?? ms('10m'),
      streamGapTimeoutMs: options.streamGapTimeoutMs ?? options.stallTimeoutMs ?? ms('5m'),
      maxTransientRetries: options.maxTransientRetries ?? 2
    },
    compression: {
      enabled: true,
      keepRecentTokens: options.compressionKeepRecentTokens ?? 20_000,
      maxOverflowRetries: 1,
      reserveTokens: 0,
      microcompactEnabled: false,
      microcompactKeepRecent: 6
    },
    dailyReset: {
      enabled: true,
      hour: '00:00'
    },
    primaryModel: {
      config: {
        model: 'primary',
        providerId: `${primary.provider}_local`,
        llmProvider: primary.provider,
        reasoning: 'medium'
      },
      model: primary,
      options: { reasoning: 'medium' },
      profile: 'primary'
    },
    lightModel: {
      config: { model: 'light', providerId: `${light.provider}_local`, llmProvider: light.provider, reasoning: 'low' },
      model: light,
      options: { reasoning: 'low' },
      profile: 'light'
    },
    heavyModel: {
      config: { model: 'heavy', providerId: `${heavy.provider}_local`, llmProvider: heavy.provider, reasoning: 'high' },
      model: heavy,
      options: { reasoning: 'high' },
      profile: 'heavy'
    }
  }
}

// Reads this agent's conversations oldest-first; most tests take [0] as "the"
// conversation, and multi-conversation tests (daily reset, /new) rely on this order.
async function conversationsFor(agentUid: string) {
  return DB.select()
    .from(AiAgentConversations)
    .where(eq(AiAgentConversations.agentUid, agentUid))
    .orderBy(AiAgentConversations.createdAt)
}

// Transcript in append order. The id tiebreaker keeps rows stable when several share
// a createdAt timestamp, so the role:kind:text array assertions stay deterministic.
async function messagesFor(conversationId: string) {
  return DB.select()
    .from(AiAgentMessages)
    .where(eq(AiAgentMessages.conversationId, conversationId))
    .orderBy(AiAgentMessages.createdAt, AiAgentMessages.id)
}

// LLM turns in call order, same id tiebreaker as messagesFor so kind/profile/status
// sequences are deterministic.
async function llmTurnsFor(conversationId: string) {
  return DB.select()
    .from(AiAgentLlmTurns)
    .where(eq(AiAgentLlmTurns.conversationId, conversationId))
    .orderBy(AiAgentLlmTurns.startedAt, AiAgentLlmTurns.id)
}

// Flattens a content-block array to its plain text, ignoring image/tool blocks.
function textOf(content: unknown): string {
  if (!Array.isArray(content)) return ''
  return content
    .flatMap(block =>
      typeof block === 'object' && block !== null && !Array.isArray(block) && typeof block.text === 'string'
        ? [block.text]
        : []
    )
    .join('')
}

// The transcript_effect.state marker a message carries once it has been superseded,
// recalled, etc. Recall/retry tests assert on these to confirm a row was tombstoned
// rather than deleted. Undefined means the message still counts as live.
function transcriptEffect(row: typeof AiAgentMessages.$inferSelect | undefined): string | undefined {
  const effect = row?.metadata.transcript_effect
  if (typeof effect !== 'object' || effect === null || Array.isArray(effect)) return undefined
  const state = (effect as Record<string, unknown>).state
  return typeof state === 'string' ? state : undefined
}

// The provider message ids folded into one transcript row. A single row can batch
// several inbound provider events, so tests match a message by "contains this id".
function providerMessageIds(row: typeof AiAgentMessages.$inferSelect): string[] {
  const refs = row.metadata.provider_refs
  if (typeof refs !== 'object' || refs === null || Array.isArray(refs)) return []
  const ids = (refs as Record<string, unknown>).message_ids
  return Array.isArray(ids) ? ids.filter((id): id is string => typeof id === 'string') : []
}

function jsonObjects(value: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(value)) return []
  return value.filter((item): item is Record<string, unknown> => isPlainObject(item))
}

function jsonRecord(value: unknown): Record<string, unknown> | undefined {
  return isPlainObject(value) ? value : undefined
}

function toolNameFromJson(value: Record<string, unknown>): unknown {
  return value.toolName ?? value.name
}

// Wake members are conversation ids; map them back to agents through PG.
async function ambientMemberAgents(members: string[]): Promise<Map<string, string>> {
  const ids = members.filter(member => /^[0-9a-f-]{36}$/i.test(member))
  if (ids.length === 0) return new Map()
  const rows = await DB.select({ id: AiAgentConversations.id, agentUid: AiAgentConversations.agentUid })
    .from(AiAgentConversations)
    .where(inArray(AiAgentConversations.id, ids))
  return new Map(rows.map(row => [row.id, row.agentUid]))
}

// The ambient wake set is a single Redis key shared by every agent, so a test reading
// "is anything still scheduled for me?" must filter the members down to its own agent.
async function ambientRedisMembersForAgent(agentUid: string): Promise<string[]> {
  const members = await redis.send('ZRANGE', [AMBIENT_REDIS_KEY, '0', '-1'])
  if (!Array.isArray(members)) return []
  const agents = await ambientMemberAgents(members.map(String))
  return members.map(String).filter(member => agents.get(member) === agentUid)
}

async function clearAmbientRedisMembersForTestPrefix(): Promise<void> {
  const members = await redis.send('ZRANGE', [AMBIENT_REDIS_KEY, '0', '-1']).catch(() => [])
  if (!Array.isArray(members)) return
  const agents = await ambientMemberAgents(members.map(String))
  const testMembers = members.map(String).filter(member => (agents.get(member) ?? '').includes(testPrefix))
  if (testMembers.length > 0) await redis.send('ZREM', [AMBIENT_REDIS_KEY, ...testMembers]).catch(() => undefined)
}

/**
 * Retries an assertion until it passes or the deadline elapses. The agent runs work
 * on background timers and outbox drains, so the row, outbound event, or lease state
 * under test usually appears only after some asynchronous delay rather than the moment
 * `say()` returns. On timeout it re-throws the LAST assertion failure (not a generic
 * timeout) so the reported error points at the real expectation that never held.
 */
async function eventually<T>(assertion: () => T | Promise<T>, timeoutMs = ms('4s')): Promise<T> {
  const deadline = Date.now() + timeoutMs
  let lastError: unknown

  while (Date.now() < deadline) {
    try {
      return await assertion()
    } catch (error) {
      lastError = error
      await Bun.sleep(20)
    }
  }

  // One final attempt after the deadline so a just-missed result still passes, and so
  // the thrown error is a real assertion failure rather than a bare timeout.
  return Promise.resolve(assertion()).catch((error: unknown) => {
    throw lastError ?? error
  })
}
