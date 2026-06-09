import 'reflect-metadata'
import { redis } from 'bun'
import { afterAll, afterEach, describe, expect, it } from 'bun:test'
import { and, eq, sql } from 'drizzle-orm'
import { z } from 'zod'
import { isPlainObject, ms } from '@pleisto/active-support'
import {
  fauxAssistantMessage,
  fauxToolCall,
  registerFauxProvider,
  type FauxProviderRegistration,
  type FauxResponseStep
} from '@earendil-works/pi-ai'
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

const { DB } = await import('@/common/database')
const {
  AiAgentConversations,
  AiAgentCheckbacks,
  AiAgentLlmTurns,
  AiAgentMessages,
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  ExternalGatewayOutbox,
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
const { createUserMessage } = await import('./core')
const { buildTool } = await import('./tools/build-tool')
const { AiAgentAmbientBatcher } = await import('./ambient')
const { externalGatewayOutbox } = await import('@/external-gateway/outbox')
const { externalGatewayProjectionSink } = await import('@/external-gateway/core/projection')

const testPrefix = `ai_agent_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const AMBIENT_REDIS_KEY = 'bullx-agent:ai-agent:ambient-wake'
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

describe('AIAgent pi-ai runtime', () => {
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
        row => (row.providerMetadata as JsonObject).pi_provider === setup.profile.primaryModel.config.piProvider
      )
    ).toBe(true)
    expect(turns.every(row => row.status === 'succeeded')).toBe(true)
    expect(turns.every(row => typeof (row.usage as { totalTokens?: unknown }).totalTokens === 'number')).toBe(true)
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

  it('compresses with the light model profile and edits one progress message', async () => {
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

    await eventually(() => expect(setup.platform.outbound.some(event => event.op === 'edit')).toBe(true))
    const edit = setup.platform.outbound.find(event => event.op === 'edit')!
    expect(edit.text).toBe('Conversation compressed.')
    expect(
      setup.platform.outbound.some(event => event.op === 'post' && event.text === 'Compressing conversation...')
    ).toBe(true)

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
    expect((compressionTurn.providerMetadata as JsonObject | undefined)?.pi_provider).toBe(
      setup.profile.lightModel.config.piProvider
    )
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
    expect(selectedTurns.some(row => JSON.stringify(row.response).includes('old answer'))).toBe(false)
    expect(selectedTurns.some(row => JSON.stringify(row.response).includes('retry answer'))).toBe(true)
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
    await eventually(() => expect(compressed.platform.outbound.some(event => event.op === 'edit')).toBe(true))
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
    await eventually(() =>
      expect(ended.platform.outbound.some(event => event.text === 'New conversation started.')).toBe(true)
    )
    await endedGroup.recall('m1')
    await Bun.sleep(120)

    const endedConversations = await conversationsFor(ended.agentUid)
    expect(endedConversations).toHaveLength(2)
    const oldConversation = endedConversations.find(row => row.endedAt)!
    const oldRows = await messagesFor(oldConversation.id)
    expect(oldRows.map(row => transcriptEffect(row))).toEqual([undefined, undefined])
    expect(ended.platform.outbound.some(event => event.op === 'delete')).toBe(false)
  })

  it('batches ambient may_intervene inside AIAgent and routes recognizer through the light model profile', async () => {
    const setup = await startAiAgent(
      'ambient',
      [
        fauxAssistantMessage('{"intervene":false}'),
        fauxAssistantMessage('```json\n{"intervene":true,"reason_summary":"asked for help"}\n```'),
        fauxAssistantMessage('ambient answer'),
        fauxAssistantMessage('addressed after ambient')
      ],
      { groupMessageMode: 'may_intervene', ambientBatchWindowMs: 10 }
    )
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:ambient` }))

    await group.say({ id: 'a1', text: 'just chatting' })
    await Bun.sleep(80)
    expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(0)

    await group.say({ id: 'a2', text: 'agent should help here' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'ambient answer')).toBe(true))

    const [conversation] = await conversationsFor(setup.agentUid)
    const turns = await llmTurnsFor(conversation!.id)
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toContain('ambient_recognizer:light:light')
    expect(turns.map(row => `${row.kind}:${row.profile}:${row.model}`)).toContain('generation:primary:primary')
    const ambientTurn = turns.find(row => row.kind === 'ambient_recognizer')
    expect(ambientTurn?.provider).toBe(setup.profile.lightModel.config.providerId)
    expect(ambientTurn?.callIndex).toBe(0)
    expect(ambientTurn?.leaseId).toBeTruthy()
    expect(jsonObjects(ambientTurn?.requestRefs)).not.toHaveLength(0)
    expect(
      jsonObjects(ambientTurn?.requestPatches).some(
        patch => patch.type === 'llm_request' && patch.reason === 'ambient_recognizer'
      )
    ).toBe(true)
    expect((ambientTurn?.providerMetadata as JsonObject | undefined)?.pi_provider).toBe(
      setup.profile.lightModel.config.piProvider
    )
    const rows = await messagesFor(conversation!.id)
    expect(rows.some(row => row.role === 'im_ambient' && row.kind === 'normal')).toBe(true)
    const introspection = rows.find(row => row.role === 'im_ambient' && row.kind === 'introspection')
    expect(introspection).toBeTruthy()

    await group.say({ id: 'm3', isMention: true, text: '@Agent continue from intervention' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text === 'addressed after ambient')).toBe(true)
    )
    const updatedTurns = await llmTurnsFor(conversation!.id)
    const latestGeneration = updatedTurns.filter(row => row.kind === 'generation').at(-1)!
    expect(latestGeneration.inputMessageIds).toContain(introspection!.id)
  })

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
      expect(members.some(member => member.includes(setup.adapterName))).toBe(true)
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

  it('starts a new conversation on daily reset while keeping the same conversation key', async () => {
    const setup = await startAiAgent('daily_reset', [fauxAssistantMessage('old day'), fauxAssistantMessage('new day')])
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: 'before reset' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'old day')).toBe(true))
    const [firstConversation] = await conversationsFor(setup.agentUid)
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
    expect(setup.platform.outbound.some(event => event.text === 'Stopped.')).toBe(true)
    const transcript = await messagesFor(conversation.id)
    expect(transcript.some(row => row.eventId === 'stop-command')).toBe(false)

    await dm.say({ id: 'steer-fallback-command', text: '/steer answer now' })
    await eventually(() => expect(setup.platform.outbound.some(event => event.text === 'steered answer')).toBe(true))
    const updatedTranscript = await messagesFor(conversation.id)
    expect(
      updatedTranscript.some(
        row => row.eventSource === 'ai-agent.command.steer' && textOf(row.content) === 'answer now'
      )
    ).toBe(true)
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
    expect(textOf(steering?.content)).toContain('focus on error handling')
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

  it('does not start /compress when edit is unsupported by the adapter', async () => {
    const setup = await startAiAgent('compress_unsupported', [], {
      adapterCapabilities: mockImCapabilitiesWithout('outbound', 'edit_message')
    })
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'compress-command', text: '/compress' })
    await eventually(() =>
      expect(setup.platform.outbound.some(event => event.text?.includes('message edit is unsupported'))).toBe(true)
    )
    expect(setup.platform.outbound.some(event => event.op === 'edit')).toBe(false)
    const [conversation] = await conversationsFor(setup.agentUid)
    expect((await messagesFor(conversation!.id)).filter(row => row.kind === 'summary')).toHaveLength(0)
    expect(await llmTurnsFor(conversation!.id)).toHaveLength(0)
  })

  it('compresses and retries when pi-ai reports provider context overflow', async () => {
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

  it('clarify blocks the run until the user replies, then resumes without queuing a followup', async () => {
    const clarifyRegistry = new AiAgentClarifyRegistry()
    const setup = await startAiAgent(
      'clarify_reply',
      [
        fauxAssistantMessage([fauxToolCall('clarify', { question: 'A or B?', choices: ['A', 'B'] })]),
        fauxAssistantMessage('you picked A')
      ],
      { enableClarify: true, clarifyTimeoutMs: 5_000, clarifyHeartbeatMs: 50, clarifyRegistry }
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
    const [refreshed] = await conversationsFor(setup.agentUid)
    const generation = refreshed!.generation as { pending_followups?: unknown[] }
    expect(generation.pending_followups ?? []).toHaveLength(0)

    const turns = (await llmTurnsFor(conversation!.id)).filter(row => row.kind === 'generation')
    expect(turns).toHaveLength(2)
    const toolCallTurn = turns[0]!
    const finalTurn = turns[1]!
    expect(turns.map(row => row.callIndex)).toEqual([0, 1])
    expect(new Set(turns.map(row => row.leaseId))).toEqual(new Set([toolCallTurn.leaseId]))
    expect(turns.every(row => row.status === 'succeeded')).toBe(true)

    const toolCallBlocks = jsonObjects((toolCallTurn.response as JsonObject).content)
    expect(toolCallBlocks.some(block => block.type === 'toolCall' && toolNameFromJson(block) === 'clarify')).toBe(true)
    const toolResults = jsonObjects(toolCallTurn.toolResults)
    expect(toolResults.some(result => result.role === 'toolResult' && toolNameFromJson(result) === 'clarify')).toBe(
      true
    )

    const finalRefs = jsonObjects(finalTurn.requestRefs)
    expect(finalRefs.some(ref => ref.type === 'llm_turn_response' && ref.llm_turn_id === toolCallTurn.id)).toBe(true)
    expect(finalRefs.some(ref => ref.type === 'llm_turn_tool_result' && ref.llm_turn_id === toolCallTurn.id)).toBe(true)
    expect(finalRefs.some(ref => ref.type === 'inline_agent_message')).toBe(false)
    expect((finalTurn.requestContext as Record<string, unknown>).messages).toBeUndefined()

    const toolDefinitionPatches = jsonObjects(toolCallTurn.requestPatches).filter(
      patch => patch.type === 'llm_tool_definitions'
    )
    expect(toolDefinitionPatches).toHaveLength(1)
    expect(jsonObjects(finalTurn.requestPatches).some(patch => patch.type === 'llm_tool_definitions')).toBe(false)
    const tools = jsonObjects(toolDefinitionPatches[0]?.tools)
    const clarifyTool = tools.find(tool => tool.name === 'clarify')
    expect(clarifyTool).toBeTruthy()
    expect(JSON.stringify(clarifyTool?.parameters)).toContain('question')

    const trajectory = reconstructLlmTurnTrajectory({
      turns,
      messages: await messagesFor(conversation!.id)
    })
    const firstCall = trajectory[0]!
    const secondCall = trajectory[1]!
    expect(firstCall.request.systemPrompt).toBe('You are a BullX AI coworker. Reply in plain text.')
    expect(firstCall.request.messages.map(message => message.role)).toEqual(['user'])
    expect(firstCall.request.tools.some(tool => jsonRecord(tool)?.name === 'clarify')).toBe(true)
    expect(
      jsonObjects(firstCall.response.content).some(
        block => block.type === 'toolCall' && toolNameFromJson(block) === 'clarify'
      )
    ).toBe(true)
    expect(
      jsonObjects(firstCall.toolResults).some(result => result.role === 'toolResult' && result.toolName === 'clarify')
    ).toBe(true)
    expect(secondCall.request.exactLlmRequest).toBe(false)
    expect(secondCall.request.messages.map(message => message.role)).toEqual(['user', 'assistant', 'toolResult'])
    expect(secondCall.request.tools.some(tool => jsonRecord(tool)?.name === 'clarify')).toBe(true)
    expect(jsonObjects(secondCall.request.patches).some(patch => patch.type === 'llm_tool_definitions')).toBe(false)
  })

  it('clarify times out and the run continues', async () => {
    const clarifyRegistry = new AiAgentClarifyRegistry()
    const setup = await startAiAgent(
      'clarify_timeout',
      [
        fauxAssistantMessage([fauxToolCall('clarify', { question: 'still there?' })]),
        fauxAssistantMessage('moving on')
      ],
      { enableClarify: true, clarifyTimeoutMs: 80, clarifyHeartbeatMs: 1_000, clarifyRegistry }
    )
    const dm = setup.platform.dm(setup.conversationOptions())

    await dm.say({ id: 'm1', text: '@Agent help' })
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
      { enableClarify: true, clarifyTimeoutMs: 5_000, clarifyHeartbeatMs: 50, clarifyRegistry }
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
        clarifyHeartbeatMs: 50,
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

async function startAiAgent(
  name: string,
  responses: FauxResponseStep[],
  options: {
    adapterCapabilities?: ExternalGatewayAdapterCapabilities
    ambientBatchWindowMs?: number
    compressionKeepRecentTokens?: number
    groupMessageMode?: 'observe_all' | 'may_intervene'
    clarifyTimeoutMs?: number
    clarifyHeartbeatMs?: number
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
      { id: 'primary', contextWindow: 4096 },
      { id: 'light', contextWindow: 4096 },
      { id: 'heavy', contextWindow: 4096 }
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
    loadProfile: async () => profile,
    clarifyTimeoutMs: options.clarifyTimeoutMs,
    clarifyHeartbeatMs: options.clarifyHeartbeatMs,
    clarify: options.clarifyRegistry
  })
  if (options.tools) aiRuntime.setTools(options.tools, options.activeToolNames ?? options.tools.map(tool => tool.name))
  if (options.enableClarify) aiRuntime.setClarifyEnabled(true)
  const runtime = new ExternalGatewayRuntime()
  runtimes.add(runtime)
  await runtime.start({
    agentExecutor: aiRuntime,
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

function runtimeProfile(
  registration: FauxProviderRegistration,
  options: { ambientBatchWindowMs?: number; compressionKeepRecentTokens?: number }
): AiAgentRuntimeProfile {
  const primary = registration.getModel('primary')!
  const light = registration.getModel('light')!
  const heavy = registration.getModel('heavy')!
  return {
    ambient: {
      batchWindowMs: options.ambientBatchWindowMs ?? 20,
      freshnessMs: 5_000
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
      hour: '00:00',
      retryMinutes: 30,
      timezone: 'Etc/UTC'
    },
    primaryModel: {
      config: {
        model: 'primary',
        providerId: `${primary.provider}_local`,
        piProvider: primary.provider,
        reasoning: 'medium'
      },
      model: primary,
      options: { reasoning: 'medium' },
      profile: 'primary'
    },
    lightModel: {
      config: { model: 'light', providerId: `${light.provider}_local`, piProvider: light.provider, reasoning: 'low' },
      model: light,
      options: { reasoning: 'low' },
      profile: 'light'
    },
    heavyModel: {
      config: { model: 'heavy', providerId: `${heavy.provider}_local`, piProvider: heavy.provider, reasoning: 'high' },
      model: heavy,
      options: { reasoning: 'high' },
      profile: 'heavy'
    }
  }
}

async function conversationsFor(agentUid: string) {
  return DB.select()
    .from(AiAgentConversations)
    .where(eq(AiAgentConversations.agentUid, agentUid))
    .orderBy(AiAgentConversations.createdAt)
}

async function messagesFor(conversationId: string) {
  return DB.select()
    .from(AiAgentMessages)
    .where(eq(AiAgentMessages.conversationId, conversationId))
    .orderBy(AiAgentMessages.createdAt, AiAgentMessages.id)
}

async function llmTurnsFor(conversationId: string) {
  return DB.select()
    .from(AiAgentLlmTurns)
    .where(eq(AiAgentLlmTurns.conversationId, conversationId))
    .orderBy(AiAgentLlmTurns.startedAt, AiAgentLlmTurns.id)
}

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

function transcriptEffect(row: typeof AiAgentMessages.$inferSelect | undefined): string | undefined {
  const effect = row?.metadata.transcript_effect
  if (typeof effect !== 'object' || effect === null || Array.isArray(effect)) return undefined
  const state = (effect as Record<string, unknown>).state
  return typeof state === 'string' ? state : undefined
}

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

async function ambientRedisMembersForAgent(agentUid: string): Promise<string[]> {
  const members = await redis.send('ZRANGE', [AMBIENT_REDIS_KEY, '0', '-1'])
  if (!Array.isArray(members)) return []
  return members.map(String).filter(member => member.includes(agentUid))
}

async function clearAmbientRedisMembersForTestPrefix(): Promise<void> {
  const members = await redis.send('ZRANGE', [AMBIENT_REDIS_KEY, '0', '-1']).catch(() => [])
  if (!Array.isArray(members)) return
  const testMembers = members.map(String).filter(member => member.includes(testPrefix))
  if (testMembers.length > 0) await redis.send('ZREM', [AMBIENT_REDIS_KEY, ...testMembers]).catch(() => undefined)
}

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

  return Promise.resolve(assertion()).catch((error: unknown) => {
    throw lastError ?? error
  })
}
