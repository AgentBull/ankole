import 'reflect-metadata'
import { afterAll, afterEach, describe, expect, it } from 'bun:test'
import { and, eq } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { ChannelAdapterCapabilities } from './core'
import type {
  MockImConversation,
  MockImConversationOptions,
  MockImGroupMessageMode,
  MockImPlatform as MockImPlatformInstance,
  MockImVisibleMessage
} from './testing/mock-im-adapter'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const {
  ChatChannels,
  ChatMessages,
  ChatStateCache,
  ChatStateLists,
  ChatStateLocks,
  ChatStateQueues,
  ChatStateSubscriptions
} = await import('@/common/db-schema')
const { ChatGatewayRuntime } = await import('./runtime')
const { registerChatGatewayAdapterFactory } = await import('./adapter-registry')
const { fullMockImCapabilities, mockImCapabilitiesWithout, MockImPlatform: MockImPlatformCtor } = await import(
  './testing/mock-im-adapter'
)

const testPrefix = `mockim_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const factoryPrefix = `${testPrefix}_factory`
const projectedChannelIds = new Set<string>()
const runtimeStatePrefixes = new Set<string>()
const startedRuntimes = new Set<InstanceType<typeof ChatGatewayRuntime>>()

afterEach(async () => {
  for (const runtime of startedRuntimes) await runtime.stop()
  startedRuntimes.clear()
})

afterAll(async () => {
  for (const keyPrefix of runtimeStatePrefixes) await cleanupStateRows(keyPrefix)
  for (const channelId of projectedChannelIds) await DB.delete(ChatChannels).where(eq(ChatChannels.id, channelId))
})

describe('Chat Gateway Mock IM adapter integration', () => {
  const admissionCases: Array<{
    expectObserved: boolean
    expectReply: boolean
    isMention?: boolean
    mode: MockImGroupMessageMode
    name: string
    surface: 'dm' | 'group'
    text: string
  }> = [
    {
      expectObserved: true,
      expectReply: true,
      mode: 'observe_all',
      name: 'dm is always addressed',
      surface: 'dm',
      text: 'hello from dm'
    },
    {
      expectObserved: false,
      expectReply: false,
      isMention: false,
      mode: 'addressed_only',
      name: 'addressed_only ignores ambient group messages',
      surface: 'group',
      text: 'ambient group note'
    },
    {
      expectObserved: false,
      expectReply: false,
      isMention: false,
      mode: 'addressed_only',
      name: 'literal at text is not a structured mention',
      surface: 'group',
      text: '@Agent as plain text'
    },
    {
      expectObserved: true,
      expectReply: false,
      isMention: false,
      mode: 'observe_all',
      name: 'observe_all records ambient group messages',
      surface: 'group',
      text: 'ambient but observed'
    },
    {
      expectObserved: true,
      expectReply: false,
      isMention: false,
      mode: 'may_intervene',
      name: 'may_intervene currently records ambient like observe_all',
      surface: 'group',
      text: 'ambient may intervene later'
    },
    {
      expectObserved: true,
      expectReply: true,
      isMention: true,
      mode: 'addressed_only',
      name: 'structured group mention is addressed',
      surface: 'group',
      text: '@Agent inspect this'
    }
  ]

  for (const [index, testCase] of admissionCases.entries()) {
    it(`admits inbound latest-state by policy: ${testCase.name}`, async () => {
      const setup = await startMockRuntime(`admission_${index}`, {
        groupMessageMode: testCase.mode
      })
      const conversation =
        testCase.surface === 'dm'
          ? setup.platform.dm(setup.conversationOptions({ channelId: `${setup.adapterName}:dm-user` }))
          : setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

      await conversation.say({
        id: 'm1',
        isMention: testCase.isMention,
        text: testCase.text
      })

      if (testCase.expectReply) {
        await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
      } else {
        await Bun.sleep(100)
        expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(0)
      }

      if (testCase.expectObserved) {
        await assertMirrorEqualsPlatform(setup.platform, conversation.channelId)
      } else {
        await assertNoProjectedMessage(conversation.channelId, 'm1')
        expect(setup.platform.visibleMessages(conversation.channelId)).toEqual([])
      }

      await setup.runtime.stop()
    })
  }

  it('updates inbound mirror and deletes the reply when a mentioned group message is edited into ambient', async () => {
    const setup = await startMockRuntime('addressed_to_ambient')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent summarize this' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))

    await group.edit('m1', { isMention: false, text: 'summarize this' })

    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'delete')).toHaveLength(1))
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })

  it('keeps a visible bot reply mirrored when the channel cannot delete replies', async () => {
    const setup = await startMockRuntime('no_delete', {
      capabilities: mockImCapabilitiesWithout('outbound', 'delete_message')
    })
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent investigate' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))

    await group.edit('m1', { isMention: false, text: 'investigate' })
    await Bun.sleep(100)

    expect(setup.platform.outbound.filter(event => event.op === 'delete')).toHaveLength(0)
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })

  it('does not let stale receive overwrite edit-before-receive latest-state or create duplicate replies', async () => {
    const setup = await startMockRuntime('edit_before_receive')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))
    const sentAt = new Date('2026-06-04T01:00:00.000Z')
    const editedAt = new Date('2026-06-04T01:01:00.000Z')

    await group.edit('m1', {
      dateSent: sentAt,
      editedAt,
      isMention: true,
      text: '@Agent edited first'
    })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))

    await group.say({
      dateSent: sentAt,
      id: 'm1',
      isMention: true,
      text: '@Agent original late receive'
    })
    await Bun.sleep(150)

    expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1)
    await assertProjectedMessageText(group.channelId, 'm1', '@Agent edited first')
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })

  it('keeps recall-before-receive terminal so stale receives cannot resurrect the message or reply', async () => {
    const setup = await startMockRuntime('recall_before_receive')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))
    const sentAt = new Date('2026-06-04T02:00:00.000Z')
    const deletedAt = new Date('2026-06-04T02:01:00.000Z')

    await group.recall('m1', { deletedAt })
    await group.say({
      dateSent: sentAt,
      id: 'm1',
      isMention: true,
      text: '@Agent stale receive after recall'
    })
    await Bun.sleep(150)

    expect(setup.platform.outbound).toEqual([])
    await assertNoProjectedMessage(group.channelId, 'm1')
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })

  it('keeps inbound mirror aligned when post/edit/delete side effects fail and then retry', async () => {
    const setup = await startMockRuntime('side_effect_retry')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: false, text: 'ambient first' })
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)

    setup.platform.failNext('post')
    await expect(group.edit('m1', { isMention: true, text: '@Agent now addressed' })).rejects.toThrow('mock im post failure')
    expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(0)
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)

    await group.edit('m1', { isMention: true, text: '@Agent now addressed' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)

    setup.platform.failNext('edit')
    await expect(group.edit('m1', { isMention: true, text: '@Agent edited addressed' })).rejects.toThrow(
      'mock im edit failure'
    )
    await assertProjectedMessageText(group.channelId, 'm1', '@Agent edited addressed')
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)

    await group.edit('m1', { isMention: true, text: '@Agent edited addressed' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'edit')).toHaveLength(1))
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)

    setup.platform.failNext('delete')
    await expect(group.edit('m1', { isMention: false, text: 'edited ambient' })).rejects.toThrow(
      'mock im delete failure'
    )
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)

    await group.edit('m1', { isMention: false, text: 'edited ambient' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'delete')).toHaveLength(1))
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })

  it('uses raw reaction keys and preserves reactions through message re-projection', async () => {
    const setup = await startMockRuntime('reaction_projection')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent react here' })
    await group.react({ actorId: 'user-2', messageId: 'm1', rawEmoji: 'LARK_OK' })

    await eventually(async () => {
      const row = await projectedMessage(group.channelId, 'm1')
      expect(Object.keys((row?.reactions ?? {}) as Record<string, unknown>)).toEqual(['LARK_OK'])
    })

    await group.edit('m1', { isMention: true, text: '@Agent edited with reaction intact' })
    await eventually(async () => {
      const row = await projectedMessage(group.channelId, 'm1')
      expect(Object.keys((row?.reactions ?? {}) as Record<string, unknown>)).toEqual(['LARK_OK'])
      expect(row?.text).toBe('@Agent edited with reaction intact')
    })

    await group.unreact({ actorId: 'user-2', messageId: 'm1', rawEmoji: 'LARK_OK' })
    await eventually(async () => {
      const row = await projectedMessage(group.channelId, 'm1')
      expect(row?.reactions).toEqual({})
    })
  })

  it('does not collide when two adapters observe the same provider message id', async () => {
    const setup = await startMockRuntime('many_adapters', {
      adapters: ['mock_a', 'mock_b']
    })
    const first = setup.platform.group(
      setup.conversationOptions({ adapterName: 'mock_a', channelId: 'mock_a:group', channelName: 'mock_a' })
    )
    const second = setup.platform.group(
      setup.conversationOptions({ adapterName: 'mock_b', channelId: 'mock_b:group', channelName: 'mock_b' })
    )

    await first.say({ id: 'same-provider-id', isMention: true, text: '@Agent from A' })
    await second.say({ id: 'same-provider-id', isMention: true, text: '@Agent from B' })

    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(2))
    await assertProjectedMessageText(first.channelId, 'same-provider-id', '@Agent from A')
    await assertProjectedMessageText(second.channelId, 'same-provider-id', '@Agent from B')
    await assertMirrorEqualsPlatform(setup.platform, first.channelId)
    await assertMirrorEqualsPlatform(setup.platform, second.channelId)
  })

  it('keeps reply-link state isolated when multiple agents observe the same group', async () => {
    const platform: MockImPlatformInstance = new MockImPlatformCtor()
    const adapterName = 'shared_group'
    const factoryId = `${factoryPrefix}_shared_group`
    const firstAgent = `${testPrefix}_agent_one`
    const secondAgent = `${testPrefix}_agent_two`
    const statePrefixes = [`bullx-agent:${firstAgent}`, `bullx-agent:${secondAgent}`]
    for (const prefix of statePrefixes) runtimeStatePrefixes.add(prefix)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: context =>
        platform.createAdapter(context.channel.name, {
          capabilities: fullMockImCapabilities,
          groupMessageMode: 'observe_all'
        })
    })

    const runtime = new ChatGatewayRuntime()
    startedRuntimes.add(runtime)
    await runtime.start({
      loadActiveAgents: async () => [
        agentResult(firstAgent, [{ adapter: factoryId, name: adapterName }]),
        agentResult(secondAgent, [{ adapter: factoryId, name: adapterName }])
      ]
    })

    const channelId = `${adapterName}:group`
    projectedChannelIds.add(channelId)
    const first = platform.group({
      adapterName,
      agentUid: firstAgent,
      channelId,
      channelName: adapterName,
      deliver: runtime.handleWebhook.bind(runtime),
      mode: 'observe_all',
      threadId: `${channelId}:thread`
    })
    const second = platform.group({
      adapterName,
      agentUid: secondAgent,
      channelId,
      channelName: adapterName,
      deliver: runtime.handleWebhook.bind(runtime),
      mode: 'observe_all',
      threadId: `${channelId}:thread`
    })

    await first.say({ id: 'm1', isMention: true, text: '@Agent shared group' })
    await second.say({ id: 'm1', isMention: true, text: '@Agent shared group' })
    await eventually(() => expect(platform.outbound.filter(event => event.op === 'post')).toHaveLength(2))

    await first.edit('m1', { isMention: false, text: 'shared group' })
    await second.edit('m1', { isMention: false, text: 'shared group' })
    await eventually(() => expect(platform.outbound.filter(event => event.op === 'delete')).toHaveLength(2))
    await assertMirrorEqualsPlatform(platform, channelId)

    await runtime.stop()
  })
})

interface MockRuntimeSetupOptions {
  adapters?: string[]
  capabilities?: ChannelAdapterCapabilities
  groupMessageMode?: MockImGroupMessageMode
}

async function startMockRuntime(
  name: string,
  options: MockRuntimeSetupOptions = {}
): Promise<{
  adapterName: string
  conversationOptions: (overrides?: Partial<MockImConversationOptions>) => MockImConversationOptions
  platform: MockImPlatformInstance
  runtime: InstanceType<typeof ChatGatewayRuntime>
}> {
  const platform: MockImPlatformInstance = new MockImPlatformCtor()
  const adapterNames = options.adapters ?? [`mock_${name}`]
  const factoryId = `${factoryPrefix}_${name}`
  const agentUid = `${testPrefix}_${name}`
  const statePrefix = `bullx-agent:${agentUid}`
  runtimeStatePrefixes.add(statePrefix)

  registerChatGatewayAdapterFactory({
    id: factoryId,
    create: context =>
      platform.createAdapter(context.channel.name, {
        capabilities: options.capabilities ?? fullMockImCapabilities,
        groupMessageMode: options.groupMessageMode ?? 'observe_all'
      })
  })

  const runtime = new ChatGatewayRuntime()
  startedRuntimes.add(runtime)
  await runtime.start({
    loadActiveAgents: async () => [
      agentResult(
        agentUid,
        adapterNames.map(adapterName => ({ adapter: factoryId, name: adapterName }))
      )
    ]
  })

  const defaultAdapterName = adapterNames[0]!
  return {
    adapterName: defaultAdapterName,
    conversationOptions: overrides => {
      const adapterName = overrides?.adapterName ?? defaultAdapterName
      const channelId = overrides?.channelId ?? `${adapterName}:group`
      projectedChannelIds.add(channelId)
      return {
        adapterName,
        agentUid,
        channelId,
        channelName: overrides?.channelName ?? adapterName,
        deliver: runtime.handleWebhook.bind(runtime),
        mode: options.groupMessageMode ?? 'observe_all',
        threadId: overrides?.threadId ?? `${channelId}:thread`
      }
    },
    platform,
    runtime
  }
}

function agentResult(uid: string, adapters: Array<{ adapter: string; enabled?: boolean; name: string }>) {
  const normalizedUid = uid.toLowerCase()
  const now = new Date()

  return {
    principal: {
      id: crypto.randomUUID(),
      uid: normalizedUid,
      type: 'agent',
      status: 'active',
      displayName: normalizedUid,
      avatarUrl: null,
      createdAt: now,
      updatedAt: now
    },
    agent: {
      uid: normalizedUid,
      type: 'llm_agentic_loop',
      metadata: {
        chat: {
          adapters
        }
      },
      createdByPrincipalUid: null,
      createdAt: now,
      updatedAt: now
    }
  } as never
}

async function assertMirrorEqualsPlatform(platform: MockImPlatformInstance, channelId: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select().from(ChatMessages).where(eq(ChatMessages.channelId, channelId))
    expect(rows.map(mirrorProjection).sort(sortMirror)).toEqual(
      platform.visibleMessages(channelId).map(platformProjection).sort(sortMirror)
    )
  })
}

function mirrorProjection(row: typeof ChatMessages.$inferSelect) {
  return {
    authorId: row.authorId,
    channelId: row.channelId,
    id: row.messageId,
    isBot: row.authorId === 'self',
    isMention: row.isMention,
    reactions: reactionProjection(row.reactions as Record<string, unknown>),
    text: row.text ?? '',
    threadId: row.threadId
  }
}

function platformProjection(message: MockImVisibleMessage) {
  return {
    authorId: message.authorId,
    channelId: message.channelId,
    id: message.id,
    isBot: message.isBot,
    isMention: message.isMention,
    reactions: reactionProjection(message.reactions as Record<string, unknown>),
    text: message.text,
    threadId: message.threadId
  }
}

function reactionProjection(reactions: Record<string, unknown>) {
  return Object.fromEntries(
    Object.entries(reactions).map(([key, value]) => {
      const input = value as { actors?: Record<string, unknown>; count?: number; rawEmoji?: string }
      return [
        key,
        {
          actors: Object.keys(input.actors ?? {}).sort(),
          count: input.count ?? 0,
          rawEmoji: input.rawEmoji ?? key
        }
      ]
    })
  )
}

function sortMirror(left: ReturnType<typeof mirrorProjection>, right: ReturnType<typeof mirrorProjection>): number {
  return left.id.localeCompare(right.id)
}

async function assertProjectedMessageText(channelId: string, messageId: string, text: string): Promise<void> {
  await eventually(async () => {
    const row = await projectedMessage(channelId, messageId)
    expect(row?.text).toBe(text)
  })
}

async function assertNoProjectedMessage(channelId: string, messageId: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select()
      .from(ChatMessages)
      .where(and(eq(ChatMessages.channelId, channelId), eq(ChatMessages.messageId, messageId)))
      .limit(1)
    expect(rows).toEqual([])
  })
}

async function projectedMessage(channelId: string, messageId: string) {
  const rows = await DB.select()
    .from(ChatMessages)
    .where(and(eq(ChatMessages.channelId, channelId), eq(ChatMessages.messageId, messageId)))
    .limit(1)

  return rows[0]
}

async function eventually(assertion: () => void | Promise<void>, timeoutMs = 1_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  let lastError: unknown

  while (Date.now() < deadline) {
    try {
      await assertion()
      return
    } catch (error) {
      lastError = error
      await Bun.sleep(20)
    }
  }

  await Promise.resolve(assertion()).catch((error: unknown) => {
    throw lastError ?? error
  })
}

async function cleanupStateRows(keyPrefix: string) {
  await DB.delete(ChatStateSubscriptions).where(eq(ChatStateSubscriptions.keyPrefix, keyPrefix))
  await DB.delete(ChatStateLocks).where(eq(ChatStateLocks.keyPrefix, keyPrefix))
  await DB.delete(ChatStateCache).where(eq(ChatStateCache.keyPrefix, keyPrefix))
  await DB.delete(ChatStateLists).where(eq(ChatStateLists.keyPrefix, keyPrefix))
  await DB.delete(ChatStateQueues).where(eq(ChatStateQueues.keyPrefix, keyPrefix))
}
