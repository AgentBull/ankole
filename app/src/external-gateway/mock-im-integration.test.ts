import 'reflect-metadata'
import { afterAll, afterEach, describe, expect, it } from 'bun:test'
import { and, eq } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type {
  MockImConversationOptions,
  MockImGroupMessageMode,
  MockImPlatform as MockImPlatformInstance,
  MockImVisibleMessage
} from './testing/mock-im-adapter'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const {
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  ExternalGatewayOutbox,
  ExternalMessages,
  ExternalRooms
} = await import('@/common/db-schema')
const { ExternalGatewayRuntime } = await import('./runtime')
const { registerExternalGatewayAdapterFactory } = await import('./adapter-registry')
const { fullMockImCapabilities, MockImPlatform: MockImPlatformCtor } = await import('./testing/mock-im-adapter')

const testPrefix = `mockim_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const factoryPrefix = `${testPrefix}_factory`
const agentUids = new Set<string>()
const projectedRoomIds = new Set<string>()
const startedRuntimes = new Set<InstanceType<typeof ExternalGatewayRuntime>>()

afterEach(async () => {
  for (const runtime of startedRuntimes) await runtime.stop()
  startedRuntimes.clear()
})

afterAll(async () => {
  for (const agentUid of agentUids) {
    await DB.delete(ExternalGatewayOutbox).where(eq(ExternalGatewayOutbox.agentUid, agentUid))
    await DB.delete(ExternalGatewayAgentEvents).where(eq(ExternalGatewayAgentEvents.agentUid, agentUid))
    await DB.delete(ExternalGatewayInputTombstones).where(eq(ExternalGatewayInputTombstones.agentUid, agentUid))
  }
  for (const roomId of projectedRoomIds) await DB.delete(ExternalRooms).where(eq(ExternalRooms.id, roomId))
})

describe('External Gateway Mock IM adapter integration', () => {
  const admissionCases: Array<{
    expectDelivery?: 'addressed' | 'ambient'
    expectObserved: boolean
    expectOutbound: boolean
    isMention?: boolean
    mode: MockImGroupMessageMode
    name: string
    surface: 'dm' | 'group'
    text: string
  }> = [
    {
      expectDelivery: 'addressed',
      expectObserved: true,
      expectOutbound: true,
      mode: 'observe_all',
      name: 'dm is always addressed',
      surface: 'dm',
      text: 'hello from dm'
    },
    {
      expectObserved: false,
      expectOutbound: false,
      isMention: false,
      mode: 'addressed_only',
      name: 'addressed_only ignores non-addressed group messages',
      surface: 'group',
      text: 'ambient group note'
    },
    {
      expectObserved: false,
      expectOutbound: false,
      isMention: false,
      mode: 'addressed_only',
      name: 'literal at text is not a structured mention',
      surface: 'group',
      text: '@Agent as plain text'
    },
    {
      expectObserved: true,
      expectOutbound: false,
      isMention: false,
      mode: 'observe_all',
      name: 'observe_all mirrors non-addressed group messages only',
      surface: 'group',
      text: 'ambient but observed'
    },
    {
      expectDelivery: 'ambient',
      expectObserved: true,
      expectOutbound: false,
      isMention: false,
      mode: 'may_intervene',
      name: 'may_intervene mirrors and delivers ambient events',
      surface: 'group',
      text: 'ambient may intervene'
    },
    {
      expectDelivery: 'addressed',
      expectObserved: true,
      expectOutbound: true,
      isMention: true,
      mode: 'addressed_only',
      name: 'structured group mention is addressed',
      surface: 'group',
      text: '@Agent inspect this'
    }
  ]

  for (const [index, testCase] of admissionCases.entries()) {
    it(`applies group_message_mode policy: ${testCase.name}`, async () => {
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

      if (testCase.expectOutbound) {
        await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
      } else {
        await Bun.sleep(150)
        expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(0)
      }

      if (testCase.expectObserved) {
        await assertMirrorEqualsPlatform(setup.platform, conversation.channelId)
      } else {
        await assertNoProjectedMessage(conversation.channelId, 'm1')
        expect(setup.platform.visibleMessages(conversation.channelId)).toEqual([])
      }

      if (testCase.expectDelivery) {
        await assertAgentEventDone(setup.agentUid, 'message.received', testCase.expectDelivery)
      } else {
        await assertNoAgentEvents(setup.agentUid)
      }
    })
  }

  it('batches consecutive normal addressed messages from the same actor', async () => {
    const setup = await startMockRuntime('same_actor_batch')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ authorId: 'alice', id: 'm1', isMention: true, text: '@Agent first' })
    await group.say({ authorId: 'alice', id: 'm2', isMention: true, text: '@Agent second' })

    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
    expect(setup.platform.outbound[0]!.text).toContain('@Agent first\n@Agent second')
    await assertAgentEventCount(setup.agentUid, 'message.received', 'addressed', 2)
  })

  it('does not batch across another actor in the same room/thread', async () => {
    const setup = await startMockRuntime('actor_boundary')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ authorId: 'alice', id: 'a1', isMention: true, text: '@Agent alice one' })
    await group.say({ authorId: 'bob', id: 'b1', isMention: true, text: '@Agent bob' })
    await group.say({ authorId: 'alice', id: 'a2', isMention: true, text: '@Agent alice two' })

    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(3))
    expect(setup.platform.outbound.map(event => event.text)).toEqual([
      `[BullX Agent External Gateway mock:${setup.agentUid}]\n\n@Agent alice one`,
      `[BullX Agent External Gateway mock:${setup.agentUid}]\n\n@Agent bob`,
      `[BullX Agent External Gateway mock:${setup.agentUid}]\n\n@Agent alice two`
    ])
  })

  it('uses the external room as the agent session boundary', async () => {
    const setup = await startMockRuntime('session_boundary')
    const sharedRoomId = `${setup.adapterName}:shared-room`
    const firstThread = setup.platform.group(
      setup.conversationOptions({ channelId: sharedRoomId, threadId: `${sharedRoomId}:thread-a` })
    )
    const secondThread = setup.platform.group(
      setup.conversationOptions({ channelId: sharedRoomId, threadId: `${sharedRoomId}:thread-b` })
    )
    const otherRoomId = `${setup.adapterName}:other-room`
    const otherRoom = setup.platform.group(
      setup.conversationOptions({ channelId: otherRoomId, threadId: `${otherRoomId}:thread` })
    )

    await firstThread.say({ id: 'same-room-thread-a', isMention: true, text: '@Agent first thread' })
    await secondThread.say({ id: 'same-room-thread-b', isMention: true, text: '@Agent second thread' })
    await otherRoom.say({ id: 'other-room-message', isMention: true, text: '@Agent other room' })

    const sessions = await agentEventSessionsByMessageId(setup.agentUid, [
      'same-room-thread-a',
      'same-room-thread-b',
      'other-room-message'
    ])
    expect(sessions.get('same-room-thread-a')).toBe(`${setup.agentUid}:external-room:${sharedRoomId}`)
    expect(sessions.get('same-room-thread-b')).toBe(sessions.get('same-room-thread-a'))
    expect(sessions.get('other-room-message')).toBe(`${setup.agentUid}:external-room:${otherRoomId}`)
    expect(sessions.get('other-room-message')).not.toBe(sessions.get('same-room-thread-a'))
  })

  it('removes pending normal input when a message is recalled before delivery', async () => {
    const setup = await startMockRuntime('pending_delete')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent delete before delivery' })
    await group.recall('m1')

    await Bun.sleep(150)
    expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(0)
    await assertNoProjectedMessage(group.channelId, 'm1')
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })

  it('does not resurrect a stale receive when recall arrives before receive', async () => {
    const setup = await startMockRuntime('recall_before_receive')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.recall('m1')
    await group.say({ id: 'm1', isMention: true, text: '@Agent stale receive' })

    await Bun.sleep(150)
    expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(0)
    await assertNoProjectedMessage(group.channelId, 'm1')
    await assertNoAgentEvents(setup.agentUid)
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })

  it('scopes recall tombstones by external room', async () => {
    const setup = await startMockRuntime('room_scoped_tombstone')
    const first = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:room-a` }))
    const second = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:room-b` }))

    await first.recall('same-provider-id')
    await second.say({ id: 'same-provider-id', isMention: true, text: '@Agent same id in another room' })

    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
    await assertNoProjectedMessage(first.channelId, 'same-provider-id')
    await assertProjectedMessageText(second.channelId, 'same-provider-id', '@Agent same id in another room')
    await assertMirrorEqualsPlatform(setup.platform, first.channelId)
    await assertMirrorEqualsPlatform(setup.platform, second.channelId)
  })

  it('delivers /undo and /steer as typed command stubs without gateway-owned side effects', async () => {
    const setup = await startMockRuntime('command_stubs')
    const dm = setup.platform.dm(setup.conversationOptions({ channelId: `${setup.adapterName}:dm-user` }))

    await dm.say({ id: 'undo-command', text: '/undo' })
    await dm.say({ id: 'steer-command', text: '/steer be concise' })

    await assertAgentEventCount(setup.agentUid, 'slash_command', 'command', 2)
    await assertCommandPayload(setup.agentUid, 'undo-command', {
      argsText: '',
      name: 'undo',
      raw: '/undo',
      status: 'stub'
    })
    await assertCommandPayload(setup.agentUid, 'steer-command', {
      argsText: 'be concise',
      name: 'steer',
      raw: '/steer be concise',
      status: 'stub'
    })
    expect(setup.platform.outbound).toEqual([])
  })

  it('does not wake the agent when an observe_all group message is recalled', async () => {
    const setup = await startMockRuntime('observe_recall', {
      groupMessageMode: 'observe_all'
    })
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: false, text: 'ambient observed only' })
    await assertProjectedMessageText(group.channelId, 'm1', 'ambient observed only')

    await group.recall('m1')

    await assertNoProjectedMessage(group.channelId, 'm1')
    await assertNoAgentEvents(setup.agentUid)
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

    await group.unreact({ actorId: 'user-2', messageId: 'm1', rawEmoji: 'LARK_OK' })
    await eventually(async () => {
      const row = await projectedMessage(group.channelId, 'm1')
      expect(row?.reactions).toEqual({})
    })
  })

  it('does not collide when two bindings observe the same provider message id', async () => {
    const setup = await startMockRuntime('many_bindings', {
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

  it('fans out the same external room event to multiple agents without duplicating projection facts', async () => {
    const platform: MockImPlatformInstance = new MockImPlatformCtor()
    const adapterName = 'shared_group'
    const factoryId = `${factoryPrefix}_shared_group`
    const firstAgent = `${testPrefix}_agent_one`
    const secondAgent = `${testPrefix}_agent_two`
    for (const agentUid of [firstAgent, secondAgent]) {
      agentUids.add(agentUid)
    }

    registerExternalGatewayAdapterFactory({
      id: factoryId,
      create: context =>
        platform.createAdapter(context.channel.name, {
          capabilities: fullMockImCapabilities,
          groupMessageMode: 'observe_all'
        })
    })

    const runtime = new ExternalGatewayRuntime()
    startedRuntimes.add(runtime)
    await runtime.start({
      getChannelConfig: async () => ({ group_message_mode: 'observe_all' }),
      loadActiveAgents: async () => [
        agentResult(firstAgent, [{ adapter: factoryId, name: adapterName }]),
        agentResult(secondAgent, [{ adapter: factoryId, name: adapterName }])
      ]
    })

    const roomId = `${adapterName}:group`
    projectedRoomIds.add(roomId)
    const first = platform.group({
      adapterName,
      agentUid: firstAgent,
      channelId: roomId,
      channelName: adapterName,
      deliver: runtime.handleWebhook.bind(runtime),
      mode: 'observe_all',
      threadId: `${roomId}:thread`
    })
    const second = platform.group({
      adapterName,
      agentUid: secondAgent,
      channelId: roomId,
      channelName: adapterName,
      deliver: runtime.handleWebhook.bind(runtime),
      mode: 'observe_all',
      threadId: `${roomId}:thread`
    })

    await first.say({ id: 'm1', isMention: true, text: '@Agent shared group' })
    await second.say({ id: 'm1', isMention: true, text: '@Agent shared group' })

    await eventually(() => expect(platform.outbound.filter(event => event.op === 'post')).toHaveLength(2))
    const projected = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, 'm1')))
    expect(projected).toHaveLength(1)
  })

  it('keeps GitHub-like webhook facts in canonical message receive/delete projection shape', async () => {
    const setup = await startMockRuntime('github_like')
    const issueRoom = setup.platform.group(
      setup.conversationOptions({ channelId: `${setup.adapterName}:repo-issue-123` })
    )

    await issueRoom.say({
      id: 'issue-123-root',
      isMention: true,
      raw: { provider: 'github', issue: 123, action: 'opened' },
      text: 'Issue opened: production deploy fails'
    })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
    await issueRoom.delete('issue-123-root')

    await assertNoProjectedMessage(issueRoom.channelId, 'issue-123-root')
    await assertAgentEventDone(setup.agentUid, 'message.received', 'addressed')
    await assertAgentEventDone(setup.agentUid, 'message.deleted', 'lifecycle')
  })

  it('leaves bot output untouched when a delivered user message is recalled', async () => {
    const setup = await startMockRuntime('delivered_recall_boundary')
    const group = setup.platform.group(setup.conversationOptions({ channelId: `${setup.adapterName}:group` }))

    await group.say({ id: 'm1', isMention: true, text: '@Agent answer then user recalls' })
    await eventually(() => expect(setup.platform.outbound.filter(event => event.op === 'post')).toHaveLength(1))
    const botMessageId = setup.platform.outbound[0]!.messageId!
    const botText = `[BullX Agent External Gateway mock:${setup.agentUid}]\n\n@Agent answer then user recalls`
    await assertProjectedMessageText(group.channelId, botMessageId, botText)

    await group.recall('m1')

    await assertNoProjectedMessage(group.channelId, 'm1')
    await assertProjectedMessageText(group.channelId, botMessageId, botText)
    await assertAgentEventDone(setup.agentUid, 'message.received', 'addressed')
    await assertAgentEventDone(setup.agentUid, 'message.recalled', 'lifecycle')
    expect(setup.platform.outbound.map(event => event.op)).toEqual(['post'])
    await assertMirrorEqualsPlatform(setup.platform, group.channelId)
  })
})

interface MockRuntimeSetupOptions {
  adapters?: string[]
  groupMessageMode?: MockImGroupMessageMode
}

async function startMockRuntime(
  name: string,
  options: MockRuntimeSetupOptions = {}
): Promise<{
  adapterName: string
  agentUid: string
  conversationOptions: (overrides?: Partial<MockImConversationOptions>) => MockImConversationOptions
  platform: MockImPlatformInstance
  runtime: InstanceType<typeof ExternalGatewayRuntime>
}> {
  const platform: MockImPlatformInstance = new MockImPlatformCtor()
  const adapterNames = options.adapters ?? [`mock_${name}`]
  const factoryId = `${factoryPrefix}_${name}`
  const agentUid = `${testPrefix}_${name}`
  agentUids.add(agentUid)

  registerExternalGatewayAdapterFactory({
    id: factoryId,
    create: context =>
      platform.createAdapter(context.channel.name, {
        capabilities: fullMockImCapabilities,
        groupMessageMode: options.groupMessageMode ?? 'observe_all'
      })
  })

  const runtime = new ExternalGatewayRuntime()
  startedRuntimes.add(runtime)
  await runtime.start({
    getChannelConfig: async () => ({ group_message_mode: options.groupMessageMode ?? 'observe_all' }),
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
    agentUid,
    conversationOptions: overrides => {
      const adapterName = overrides?.adapterName ?? defaultAdapterName
      const channelId = overrides?.channelId ?? `${adapterName}:group`
      projectedRoomIds.add(channelId)
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
        external: {
          adapters
        }
      },
      createdByPrincipalUid: null,
      createdAt: now,
      updatedAt: now
    }
  } as never
}

async function assertMirrorEqualsPlatform(platform: MockImPlatformInstance, roomId: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select().from(ExternalMessages).where(eq(ExternalMessages.roomId, roomId))
    expect(rows.map(mirrorProjection).sort(sortMirror)).toEqual(
      platform.visibleMessages(roomId).map(platformProjection).sort(sortMirror)
    )
  })
}

function mirrorProjection(row: typeof ExternalMessages.$inferSelect) {
  return {
    authorId: row.authorId,
    channelId: row.roomId,
    id: row.messageId,
    isBot: row.authorId === 'self',
    isMention: row.mentions.length > 0,
    reactions: reactionProjection(row.reactions as Record<string, unknown>),
    text: row.text ?? ''
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
    text: message.text
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

async function assertProjectedMessageText(roomId: string, messageId: string, text: string): Promise<void> {
  await eventually(async () => {
    const row = await projectedMessage(roomId, messageId)
    expect(row?.text).toBe(text)
  })
}

async function assertProjectedMentions(roomId: string, messageId: string, mentioned: boolean): Promise<void> {
  await eventually(async () => {
    const row = await projectedMessage(roomId, messageId)
    expect((row?.mentions.length ?? 0) > 0).toBe(mentioned)
  })
}

async function assertNoProjectedMessage(roomId: string, messageId: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, messageId)))
      .limit(1)
    expect(rows).toEqual([])
  })
}

async function projectedMessage(roomId: string, messageId: string) {
  const rows = await DB.select()
    .from(ExternalMessages)
    .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, messageId)))
    .limit(1)

  return rows[0]
}

async function assertAgentEventDone(agentUid: string, type: string, deliveryMode: string): Promise<void> {
  await eventually(async () => {
    const rows = await agentEvents(agentUid, type, deliveryMode)
    expect(rows.some(row => row.status === 'done')).toBe(true)
  })
}

async function assertAgentEventCount(
  agentUid: string,
  type: string,
  deliveryMode: string,
  count: number
): Promise<void> {
  await eventually(async () => {
    const rows = await agentEvents(agentUid, type, deliveryMode)
    expect(rows.filter(row => row.status === 'done')).toHaveLength(count)
  })
}

async function assertNoAgentEvents(agentUid: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select()
      .from(ExternalGatewayAgentEvents)
      .where(eq(ExternalGatewayAgentEvents.agentUid, agentUid))
    expect(rows).toEqual([])
  })
}

async function agentEvents(agentUid: string, type: string, deliveryMode: string) {
  return DB.select()
    .from(ExternalGatewayAgentEvents)
    .where(
      and(
        eq(ExternalGatewayAgentEvents.agentUid, agentUid),
        eq(ExternalGatewayAgentEvents.type, type),
        eq(ExternalGatewayAgentEvents.deliveryMode, deliveryMode)
      )
    )
}

async function agentEventSessionsByMessageId(agentUid: string, providerMessageIds: string[]): Promise<Map<string, string>> {
  const expected = new Set(providerMessageIds)

  return eventually(async () => {
    const rows = await DB.select()
      .from(ExternalGatewayAgentEvents)
      .where(
        and(
          eq(ExternalGatewayAgentEvents.agentUid, agentUid),
          eq(ExternalGatewayAgentEvents.type, 'message.received'),
          eq(ExternalGatewayAgentEvents.deliveryMode, 'addressed')
        )
      )

    const sessions = new Map<string, string>()
    for (const row of rows) {
      if (row.status !== 'done' || !row.providerMessageId || !expected.has(row.providerMessageId)) continue

      const payload = row.payload as { data?: { session?: { id?: unknown } } }
      if (typeof payload.data?.session?.id === 'string') {
        sessions.set(row.providerMessageId, payload.data.session.id)
      }
    }

    expect(sessions.size).toBe(expected.size)
    return sessions
  })
}

async function assertCommandPayload(
  agentUid: string,
  providerMessageId: string,
  command: { argsText: string; name: string; raw: string; status: string }
): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select()
      .from(ExternalGatewayAgentEvents)
      .where(
        and(
          eq(ExternalGatewayAgentEvents.agentUid, agentUid),
          eq(ExternalGatewayAgentEvents.providerMessageId, providerMessageId),
          eq(ExternalGatewayAgentEvents.type, 'slash_command'),
          eq(ExternalGatewayAgentEvents.deliveryMode, 'command')
        )
      )
      .limit(1)

    const payload = rows[0]?.payload as { data?: { command?: unknown } } | undefined
    expect(payload?.data?.command).toEqual(command)
  })
}

async function eventually<T>(assertion: () => T | Promise<T>, timeoutMs = 3_000): Promise<T> {
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
