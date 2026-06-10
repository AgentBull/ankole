import { afterAll, describe, expect, it } from 'bun:test'
import { and, eq } from 'drizzle-orm'
import type {
  ExternalGatewayAdapter,
  ExternalGatewayAdapterContext,
  ExternalGatewayMessageInput,
  ExternalGatewayWebhookOptions
} from './core'
import type { ExternalGatewayOutboundIntent } from './outbox'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB, jsonbParam } = await import('@/common/database')
const {
  AppConfigure,
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  ExternalGatewayOutbox,
  ExternalMessages,
  ExternalRooms
} = await import('@/common/db-schema')
const { Principals } = await import('@/common/db-schema/principals')
const { createAgent } = await import('@/principals/agents/service')
const { ExternalGatewayRuntime } = await import('./runtime')
const { MissingExternalGatewayAdapterFactoryError, registerExternalGatewayAdapterFactory } =
  await import('./adapter-registry')
const { externalGatewayOutbox } = await import('./outbox')
const { externalGatewayProjectionSink } = await import('./core/projection')
const { externalGatewayRoutes } = await import('./routes')
const { PluginRuntime } = await import('@/plugins/runtime')
const { defineBullXPlugin } = await import('@agentbull/bullx-sdk/plugins')
const { mockExternalGatewayAgentExecutor } = await import('./agent')

const testPrefix = `__test-external-gateway-${Date.now()}-${Math.random().toString(36).slice(2)}`
const factoryPrefix = `test_${Date.now()}_${Math.random().toString(36).slice(2)}`
const createdAgentUids = new Set<string>()
const dynamicConfigKeys = new Set<string>()
const projectedRoomIds = new Set<string>()

afterAll(async () => {
  for (const key of dynamicConfigKeys) await DB.delete(AppConfigure).where(eq(AppConfigure.key, key))
  for (const uid of createdAgentUids) {
    await DB.delete(ExternalGatewayOutbox).where(eq(ExternalGatewayOutbox.agentUid, uid))
    await DB.delete(ExternalGatewayAgentEvents).where(eq(ExternalGatewayAgentEvents.agentUid, uid))
    await DB.delete(ExternalGatewayInputTombstones).where(eq(ExternalGatewayInputTombstones.agentUid, uid))
    await DB.delete(Principals).where(eq(Principals.uid, uid))
  }
  for (const roomId of projectedRoomIds) await DB.delete(ExternalRooms).where(eq(ExternalRooms.id, roomId))
})

describe('ExternalGatewayRuntime', () => {
  it('loads active agent bindings, handles webhooks, queues agent delivery, and projects final outbound', async () => {
    const adapter = new FakeExternalAdapter('fake')
    const factoryId = `${factoryPrefix}_factory`
    const agentUid = `${testPrefix}-agent`.toLowerCase()
    const roomId = 'fake:channel'
    createdAgentUids.add(agentUid)
    projectedRoomIds.add(roomId)

    registerExternalGatewayAdapterFactory({
      id: factoryId,
      create: context => {
        expect((context.agent as { agent: { uid: string } }).agent.uid).toBe(agentUid)
        expect(context.channel.name).toBe('fake')
        expect(context.channel.groupMessageMode).toBe('observe_all')
        expect(context.config).toEqual({ token: 'configured', group_message_mode: 'observe_all' })
        expect(typeof context.externalIdentities?.upsertPlatformSubject).toBe('function')
        expect('core' in context).toBe(false)
        expect('projection' in context).toBe(false)
        expect('messageLifecycle' in context).toBe(false)
        return adapter
      }
    })

    const runtime = new ExternalGatewayRuntime()
    const stats = await runtime.start({
      agentExecutor: mockExternalGatewayAgentExecutor,
      loadActiveAgents: async () => [
        agentResult(agentUid, [
          { name: 'fake', adapter: factoryId },
          { name: 'disabled_fake', adapter: factoryId, enabled: false }
        ]),
        agentResult(`${testPrefix}-no-bindings`, [])
      ],
      getChannelConfig: async key => {
        dynamicConfigKeys.add(key)
        return { token: 'configured', group_message_mode: 'observe_all' }
      }
    })

    expect(stats).toEqual({ readyAgents: 1, readyChannels: 1 })
    expect(adapter.initialized).toBe(1)

    const response = await runtime.handleWebhook(
      agentUid.toUpperCase(),
      'fake',
      jsonRequest({
        id: 'mention-1',
        isMention: true,
        text: '@Agent hello',
        threadId: 'fake:channel:thread-1'
      })
    )

    expect(response.status).toBe(200)
    await eventually(() => expect(adapter.posts).toHaveLength(1))
    expect(adapter.posts[0]).toEqual({
      threadId: 'fake:channel:thread-1',
      text: `[BullX Agent External Gateway mock:${agentUid}]\n\n@Agent hello`
    })

    await assertProjectedMessage({
      authorId: 'user-1',
      mentions: true,
      messageId: 'mention-1',
      roomId,
      text: '@Agent hello'
    })
    await assertProjectedMessage({
      authorId: 'self',
      mentions: false,
      messageId: 'fake-post-1',
      roomId,
      text: `[BullX Agent External Gateway mock:${agentUid}]\n\n@Agent hello`
    })
    await assertAgentEventDone(agentUid, 'message.received', 'addressed')
    await assertOutboxSent(agentUid, 'fake-post-1')

    expect((await runtime.handleWebhook('missing-agent', 'fake', jsonRequest())).status).toBe(404)
    expect((await runtime.handleWebhook(agentUid, 'missing_channel', jsonRequest())).status).toBe(404)

    await runtime.stop()
  })

  it('executes agent-owned delete outbound intents without gateway-side recall policy', async () => {
    const adapter = new FakeExternalAdapter('fake_delete')
    const factoryId = `${factoryPrefix}_delete_factory`
    const agentUid = `${testPrefix}-delete-agent`.toLowerCase()
    const roomId = 'fake_delete:channel'
    const threadId = `${roomId}:thread-1`
    createdAgentUids.add(agentUid)
    projectedRoomIds.add(roomId)
    await createAgent({ uid: agentUid })

    registerExternalGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ExternalGatewayRuntime()
    await runtime.start({
      agentExecutor: {
        async acceptExternalGatewayDelivery(delivery, context) {
          const first = delivery.events[0]
          if (!first) return { status: 'accepted' as const }

          if (first.type === 'message.received') {
            const finalPayload: ExternalGatewayOutboundIntent['finalPayload'] = first.providerEventId.includes('m-file')
              ? {
                  files: [
                    {
                      filename: 'artifact.txt',
                      mimeType: 'text/plain',
                      dataBase64: Buffer.from('artifact body').toString('base64')
                    }
                  ]
                }
              : { text: 'agent reply' }
            await context.outbox.enqueuePendingMany({
              agentUid: context.agentUid,
              bindingName: context.bindingName,
              intents: [
                {
                  operation: 'post',
                  outboundKey: `test-post:${first.providerEventId}`,
                  providerRoomId: first.providerRoomId,
                  providerThreadId: first.providerThreadId,
                  finalPayload
                }
              ]
            })
            return { status: 'accepted' as const }
          }

          if (first.type === 'message.deleted') {
            await context.outbox.enqueuePendingMany({
              agentUid: context.agentUid,
              bindingName: context.bindingName,
              intents: [
                {
                  operation: 'delete',
                  outboundKey: `test-delete:${first.providerEventId}`,
                  providerRoomId: first.providerRoomId,
                  providerThreadId: first.providerThreadId,
                  finalPayload: { targetMessageId: 'fake_delete-post-1' }
                }
              ]
            })
            return { status: 'accepted' as const }
          }

          return { status: 'accepted' as const }
        }
      },
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_delete', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_delete',
      jsonRequest({
        id: 'm1',
        isMention: true,
        text: '@Agent hello',
        threadId
      })
    )

    await eventually(() => expect(adapter.posts).toHaveLength(1))
    await assertProjectedMessage({
      authorId: 'self',
      mentions: false,
      messageId: 'fake_delete-post-1',
      roomId,
      text: 'agent reply'
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_delete',
      jsonRequest({
        id: 'm-file',
        isMention: true,
        text: '@Agent file',
        threadId
      })
    )

    await eventually(() => expect(adapter.posts).toHaveLength(2))
    const filePostable = JSON.parse(adapter.posts[1]!.text)
    expect(filePostable.markdown).toBe('')
    expect(filePostable.files[0].filename).toBe('artifact.txt')
    expect(filePostable.files[0].mimeType).toBe('text/plain')
    expect(filePostable.files[0].data).toEqual({ type: 'Buffer', data: Array.from(Buffer.from('artifact body')) })
    await assertProjectedMessage({
      authorId: 'self',
      mentions: false,
      messageId: 'fake_delete-post-2',
      roomId,
      text: '[files: artifact.txt]'
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_delete',
      jsonRequest({
        event: 'delete',
        id: 'm1',
        threadId
      })
    )

    await eventually(() => expect(adapter.deletes).toEqual([{ messageId: 'fake_delete-post-1', threadId }]))
    await assertNoProjectedMessage(roomId, 'm1')
    await assertNoProjectedMessage(roomId, 'fake_delete-post-1')
    await assertAgentEventDone(agentUid, 'message.deleted', 'lifecycle')

    await runtime.stop()
  })

  it('keeps accepted input done when provider outbound delivery fails', async () => {
    const adapter = new FakeExternalAdapter('fake_fail')
    adapter.failNextPost()
    const factoryId = `${factoryPrefix}_outbound_failure_factory`
    const agentUid = `${testPrefix}-outbound-failure-agent`.toLowerCase()
    const roomId = 'fake_fail:channel'
    const threadId = `${roomId}:thread-1`
    createdAgentUids.add(agentUid)
    projectedRoomIds.add(roomId)

    registerExternalGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ExternalGatewayRuntime()
    await runtime.start({
      agentExecutor: {
        async acceptExternalGatewayDelivery(delivery, context) {
          const first = delivery.events[0]
          if (!first) return { status: 'accepted' as const }

          await context.outbox.enqueuePendingMany({
            agentUid: context.agentUid,
            bindingName: context.bindingName,
            intents: [
              {
                operation: 'post',
                outboundKey: `test-failed-post:${first.providerEventId}`,
                providerRoomId: first.providerRoomId,
                providerThreadId: first.providerThreadId,
                finalPayload: { text: 'provider will reject this' }
              }
            ]
          })
          return { status: 'accepted' as const }
        }
      },
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_fail', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_fail',
      jsonRequest({
        id: 'm1',
        isMention: true,
        text: '@Agent fail outbound',
        threadId
      })
    )

    await assertAgentEventDone(agentUid, 'message.received', 'addressed')
    await assertOutboxOperationStatus(agentUid, 'post', 'failed')
    expect(adapter.posts).toEqual([])
    await assertProjectedMessage({
      authorId: 'user-1',
      mentions: true,
      messageId: 'm1',
      roomId,
      text: '@Agent fail outbound'
    })

    await runtime.stop()
  })

  it('does not replay unknown-after-send outbox rows when adapter cannot prove idempotency', async () => {
    const adapter = new FakeExternalAdapter('fake_unknown')
    const agentUid = `${testPrefix}-unknown-after-send-agent`.toLowerCase()
    createdAgentUids.add(agentUid)

    await DB.insert(ExternalGatewayOutbox).values({
      agentUid,
      bindingName: 'fake_unknown',
      providerRoomId: 'fake_unknown:channel',
      providerThreadId: 'fake_unknown:channel:thread-1',
      outboundKey: 'test-unknown-after-send',
      operation: 'post',
      finalPayload: jsonbParam({ text: 'maybe already sent' }),
      status: 'pending',
      platformSendStartedAt: new Date(),
      recoveryState: 'send_attempt_started'
    })

    await externalGatewayOutbox.dispatchPendingForBinding({
      adapter,
      agent: agentResult(agentUid, [{ adapter: 'fake', name: 'fake_unknown' }]),
      bindingName: 'fake_unknown',
      projection: externalGatewayProjectionSink,
      room: {}
    })

    const [row] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, agentUid),
          eq(ExternalGatewayOutbox.outboundKey, 'test-unknown-after-send')
        )
      )
      .limit(1)
    expect(row?.status).toBe('failed')
    expect(row?.recoveryState).toBe('unknown_after_send')
    expect(adapter.posts).toEqual([])
  })

  it('does not replay idempotent send attempts outside the replay window without a provider message id', async () => {
    const adapter = new FakeExternalAdapter('fake_expired_idempotency', {
      ...defaultFakeCapabilities,
      outbound: [...defaultFakeCapabilities.outbound, 'outbound_idempotency']
    })
    const agentUid = `${testPrefix}-expired-idempotency-agent`.toLowerCase()
    createdAgentUids.add(agentUid)

    await DB.insert(ExternalGatewayOutbox).values({
      agentUid,
      bindingName: 'fake_expired_idempotency',
      providerRoomId: 'fake_expired_idempotency:channel',
      providerThreadId: 'fake_expired_idempotency:channel:thread-1',
      outboundKey: 'test-expired-idempotency',
      operation: 'post',
      finalPayload: jsonbParam({ text: 'maybe already sent outside idempotency window' }),
      status: 'pending',
      platformSendStartedAt: new Date(Date.now() - 61 * 60 * 1000),
      recoveryState: 'send_attempt_started'
    })

    await externalGatewayOutbox.dispatchPendingForBinding({
      adapter,
      agent: agentResult(agentUid, [{ adapter: 'fake', name: 'fake_expired_idempotency' }]),
      bindingName: 'fake_expired_idempotency',
      projection: externalGatewayProjectionSink,
      room: {}
    })

    const [row] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, agentUid),
          eq(ExternalGatewayOutbox.outboundKey, 'test-expired-idempotency')
        )
      )
      .limit(1)
    expect(row?.status).toBe('failed')
    expect(row?.recoveryState).toBe('unknown_after_send')
    expect(adapter.posts).toEqual([])
  })

  it('marks provider HTTP 400 outbox failures permanent instead of retrying', async () => {
    const adapter = new FakeExternalAdapter('fake_bad_request', {
      ...defaultFakeCapabilities,
      outbound: [...defaultFakeCapabilities.outbound, 'outbound_idempotency']
    })
    adapter.failNextPost(1, 'Request failed with status code 400')
    const agentUid = `${testPrefix}-bad-request-agent`.toLowerCase()
    createdAgentUids.add(agentUid)

    await DB.insert(ExternalGatewayOutbox).values({
      agentUid,
      bindingName: 'fake_bad_request',
      providerRoomId: 'fake_bad_request:channel',
      providerThreadId: 'fake_bad_request:channel:thread-1',
      outboundKey: 'test-bad-request',
      operation: 'post',
      finalPayload: jsonbParam({ text: 'provider rejects bad request' }),
      status: 'pending',
      recoveryState: 'not_started'
    })

    await externalGatewayOutbox.dispatchPendingForBinding({
      adapter,
      agent: agentResult(agentUid, [{ adapter: 'fake', name: 'fake_bad_request' }]),
      bindingName: 'fake_bad_request',
      projection: externalGatewayProjectionSink,
      room: {}
    })

    const [row] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(eq(ExternalGatewayOutbox.agentUid, agentUid), eq(ExternalGatewayOutbox.outboundKey, 'test-bad-request'))
      )
      .limit(1)
    expect(row?.status).toBe('failed')
    expect(row?.recoveryState).toBe('not_started')
    expect(row?.retryCount).toBe(0)
    expect(row?.safeError).toBe('Request failed with status code 400')
  })

  it('dead-letters pending outbox rows after the retry budget is exhausted', async () => {
    const adapter = new FakeExternalAdapter('fake_retry_exhausted', {
      ...defaultFakeCapabilities,
      outbound: [...defaultFakeCapabilities.outbound, 'outbound_idempotency']
    })
    const agentUid = `${testPrefix}-retry-exhausted-agent`.toLowerCase()
    createdAgentUids.add(agentUid)

    await DB.insert(ExternalGatewayOutbox).values({
      agentUid,
      bindingName: 'fake_retry_exhausted',
      providerRoomId: 'fake_retry_exhausted:channel',
      providerThreadId: 'fake_retry_exhausted:channel:thread-1',
      outboundKey: 'test-retry-exhausted',
      operation: 'post',
      finalPayload: jsonbParam({ text: 'never sent' }),
      status: 'pending',
      retryCount: 5,
      lastError: 'rate limited',
      recoveryState: 'not_started'
    })

    await externalGatewayOutbox.dispatchPendingForBinding({
      adapter,
      agent: agentResult(agentUid, [{ adapter: 'fake', name: 'fake_retry_exhausted' }]),
      bindingName: 'fake_retry_exhausted',
      projection: externalGatewayProjectionSink,
      room: {}
    })

    const [row] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(eq(ExternalGatewayOutbox.agentUid, agentUid), eq(ExternalGatewayOutbox.outboundKey, 'test-retry-exhausted'))
      )
      .limit(1)
    expect(row?.status).toBe('failed')
    expect(row?.safeError).toBe('retry_exhausted')
    expect(adapter.posts).toEqual([])
  })

  it('dispatches minimal reaction, divider, and card outbound intents', async () => {
    const adapter = new FakeExternalAdapter('fake_ops')
    const factoryId = `${factoryPrefix}_operations_factory`
    const agentUid = `${testPrefix}-operations-agent`.toLowerCase()
    const roomId = 'fake_ops:channel'
    const threadId = `${roomId}:thread-1`
    createdAgentUids.add(agentUid)
    projectedRoomIds.add(roomId)

    registerExternalGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ExternalGatewayRuntime()
    await runtime.start({
      agentExecutor: {
        async acceptExternalGatewayDelivery(delivery, context) {
          const first = delivery.events[0]
          if (!first) return { status: 'accepted' as const }

          const intents: ExternalGatewayOutboundIntent[] = [
            {
              operation: 'reaction_add',
              outboundKey: `test-reaction:${first.providerEventId}`,
              providerRoomId: first.providerRoomId,
              providerThreadId: first.providerThreadId,
              finalPayload: { targetMessageId: 'm1', emoji: '+1' }
            },
            {
              operation: 'divider',
              outboundKey: `test-divider:${first.providerEventId}`,
              providerRoomId: first.providerRoomId,
              providerThreadId: first.providerThreadId,
              finalPayload: {}
            },
            {
              operation: 'card',
              outboundKey: `test-card:${first.providerEventId}`,
              providerRoomId: first.providerRoomId,
              providerThreadId: first.providerThreadId,
              finalPayload: {
                kind: 'interactive_output',
                output: {
                  version: 'bullx.interactive_output.v1',
                  content: { title: 'Status', body: 'Status', format: 'plain' },
                  fallbackText: 'Status'
                }
              }
            }
          ]
          await context.outbox.enqueuePendingMany({
            agentUid: context.agentUid,
            bindingName: context.bindingName,
            intents
          })
          return { status: 'accepted' as const }
        }
      },
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_ops', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_ops',
      jsonRequest({
        id: 'm1',
        isMention: true,
        text: '@Agent run operations',
        threadId
      })
    )

    await eventually(() => {
      expect(adapter.reactions).toEqual([{ added: true, emoji: '+1', messageId: 'm1', threadId }])
      expect(adapter.posts).toHaveLength(2)
    })
    await assertOutboxOperationStatus(agentUid, 'reaction_add', 'sent')
    await assertOutboxOperationStatus(agentUid, 'divider', 'sent')
    await assertOutboxOperationStatus(agentUid, 'card', 'sent')
    await assertProjectedMessageText(roomId, 'fake_ops-post-1', '[divider]')
    await assertProjectedMessageText(roomId, 'fake_ops-post-2', 'Status')
    await eventually(async () => {
      const rows = await DB.select()
        .from(ExternalMessages)
        .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, 'm1')))
        .limit(1)
      const reactions = rows[0]?.reactions as Record<string, { actors?: Record<string, unknown> }> | undefined
      expect(Object.keys(reactions?.['+1']?.actors ?? {})).toEqual(['self'])
    })

    await runtime.stop()
  })

  it('fails startup when an enabled binding references an unregistered factory', async () => {
    const runtime = new ExternalGatewayRuntime()

    await expect(
      runtime.start({
        loadActiveAgents: async () => [
          agentResult(`${testPrefix}-missing-factory`, [{ name: 'fake', adapter: `${factoryPrefix}_missing` }])
        ]
      })
    ).rejects.toThrow(MissingExternalGatewayAdapterFactoryError)
  })

  it('uses adapter factories registered by enabled trusted plugins', async () => {
    const adapter = new FakeExternalAdapter('plugin_fake')
    const pluginId = `${factoryPrefix}-plugin`.replaceAll('_', '-')
    const factoryId = `${factoryPrefix}_plugin_factory`
    const agentUid = `${testPrefix}-plugin-agent`.toLowerCase()
    createdAgentUids.add(agentUid)

    const pluginRuntime = new PluginRuntime()
    await pluginRuntime.start({
      plugins: [
        defineBullXPlugin({
          metadata: {
            id: pluginId,
            apiVersion: 1
          },
          externalGatewayAdapters: [
            {
              id: factoryId,
              create: () => adapter
            }
          ]
        })
      ],
      defaultEnabledPluginIds: [pluginId],
      getEnabledOverrides: async () => ({})
    })

    const runtime = new ExternalGatewayRuntime()
    const stats = await runtime.start({
      agentExecutor: mockExternalGatewayAgentExecutor,
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'plugin_fake', adapter: factoryId }])]
    })

    expect(stats).toEqual({ readyAgents: 1, readyChannels: 1 })
    expect(adapter.initialized).toBe(1)

    await runtime.stop()
  })

  it('relies on active-agent loading so disabled agents stay out of startup input', async () => {
    const activeUid = `${testPrefix}-active-db-agent`.toLowerCase()
    const disabledUid = `${testPrefix}-disabled-db-agent`.toLowerCase()
    createdAgentUids.add(activeUid)
    createdAgentUids.add(disabledUid)

    await createAgent({ uid: activeUid })
    await createAgent({ uid: disabledUid })
    await DB.update(Principals).set({ status: 'disabled' }).where(eq(Principals.uid, disabledUid))

    const { listActiveAgents } = await import('@/principals/agents/service')
    const activeUids = (await listActiveAgents()).map(result => result.agent.uid)

    expect(activeUids).toContain(activeUid)
    expect(activeUids).not.toContain(disabledUid)
  })
})

describe('externalGatewayRoutes', () => {
  it('binds POST /api/agents/:agentUid/webhooks/:channel to runtime.handleWebhook', async () => {
    const calls: Array<{ agentUid: string; channel: string; method: string }> = []
    const app = externalGatewayRoutes({
      handleWebhook: async (agentUid: string, channel: string, request: Request) => {
        calls.push({ agentUid, channel, method: request.method })
        return new Response('ok')
      }
    } as never)

    const response = await app.handle(
      new Request('http://localhost/api/agents/agent-1/webhooks/fake', {
        method: 'POST'
      })
    )

    expect(response.status).toBe(200)
    expect(await response.text()).toBe('ok')
    expect(calls).toEqual([{ agentUid: 'agent-1', channel: 'fake', method: 'POST' }])
  })
})

interface FakeWebhookPayload {
  event?: 'delete'
  id?: string
  isMention?: boolean
  text?: string
  threadId?: string
}

const defaultFakeCapabilities = {
  inbound: ['message_receive', 'message_recall', 'reaction_add', 'reaction_remove'],
  outbound: ['post_message', 'delete_message', 'add_reaction', 'remove_reaction', 'divider', 'card']
} as const satisfies ExternalGatewayAdapter['capabilities']

class FakeExternalAdapter implements ExternalGatewayAdapter<FakeWebhookPayload> {
  readonly userName = 'Agent'
  readonly capabilities: ExternalGatewayAdapter['capabilities']
  context: ExternalGatewayAdapterContext | undefined
  initialized = 0
  posts: Array<{ text: string; threadId: string }> = []
  deletes: Array<{ messageId: string; threadId: string }> = []
  reactions: Array<{ added: boolean; emoji: unknown; messageId: string; threadId: string }> = []
  private postFailures = 0
  private postFailureMessage = 'fake provider post failure'

  constructor(
    readonly name: string,
    capabilities: ExternalGatewayAdapter['capabilities'] = defaultFakeCapabilities
  ) {
    this.capabilities = capabilities
  }

  failNextPost(count = 1, message = 'fake provider post failure'): void {
    this.postFailures += count
    this.postFailureMessage = message
  }

  async initialize(context: ExternalGatewayAdapterContext): Promise<void> {
    this.context = context
    this.initialized += 1
  }

  async disconnect(): Promise<void> {}

  async handleWebhook(request: Request, options?: ExternalGatewayWebhookOptions): Promise<Response> {
    const payload = (await request.json()) as FakeWebhookPayload
    if (payload.event === 'delete' && payload.id) {
      await this.context?.emitMessageDeleted(
        {
          kind: 'deleted',
          messageId: payload.id,
          raw: payload,
          threadId: payload.threadId ?? `${this.name}:channel:default-thread`
        },
        options
      )
      return Response.json({ ok: true })
    }

    await this.context?.emitMessage(this.parseMessage(payload), options)
    return Response.json({ ok: true })
  }

  parseMessage(raw: FakeWebhookPayload): ExternalGatewayMessageInput<FakeWebhookPayload> {
    return messageFromPayload(this.name, raw)
  }

  channelIdFromThreadId(threadId: string): string {
    return threadId.split(':').slice(0, 2).join(':')
  }

  decodeThreadId(threadId: string): string {
    return threadId
  }

  encodeThreadId(threadId: string): string {
    return threadId
  }

  isDM(threadId: string): boolean {
    return threadId.startsWith(`${this.name}:dm:`)
  }

  async fetchThread(threadId: string) {
    return {
      id: threadId,
      channelId: this.channelIdFromThreadId(threadId),
      isDM: this.isDM(threadId),
      metadata: {}
    }
  }

  async postMessage(threadId: string, message: unknown) {
    if (this.postFailures > 0) {
      this.postFailures -= 1
      throw new Error(this.postFailureMessage)
    }

    const text = typeof message === 'string' ? message : JSON.stringify(message)
    this.posts.push({ threadId, text })
    return {
      id: `${this.name}-post-${this.posts.length}`,
      threadId,
      raw: { text }
    }
  }

  async deleteMessage(threadId: string, messageId: string): Promise<void> {
    this.deletes.push({ messageId, threadId })
  }

  async addReaction(threadId: string, messageId: string, emoji: unknown): Promise<void> {
    this.reactions.push({ added: true, emoji, messageId, threadId })
  }

  async removeReaction(threadId: string, messageId: string, emoji: unknown): Promise<void> {
    this.reactions.push({ added: false, emoji, messageId, threadId })
  }

  renderFormatted(): string {
    return ''
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
      metadata:
        adapters.length === 0
          ? {}
          : {
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

function messageFromPayload(
  adapterName: string,
  payload: FakeWebhookPayload
): ExternalGatewayMessageInput<FakeWebhookPayload> {
  const id = payload.id ?? crypto.randomUUID()
  const text = payload.text ?? ''

  return {
    id,
    threadId: payload.threadId ?? `${adapterName}:channel:default-thread`,
    text,
    formatted: {
      type: 'root',
      children: [
        {
          type: 'paragraph',
          children: [{ type: 'text', value: text }]
        }
      ]
    } as never,
    raw: payload,
    author: {
      userId: 'user-1',
      userName: 'user',
      fullName: 'User',
      isBot: false,
      isMe: false
    },
    metadata: {
      dateSent: new Date()
    },
    attachments: [],
    isMention: payload.isMention
  }
}

function jsonRequest(payload: FakeWebhookPayload = {}): Request {
  return new Request('http://localhost/webhook', {
    method: 'POST',
    body: JSON.stringify(payload),
    headers: {
      'content-type': 'application/json'
    }
  })
}

async function assertProjectedMessage(input: {
  authorId: string
  mentions: boolean
  messageId: string
  roomId: string
  text: string
}): Promise<void> {
  await eventually(async () => {
    const rooms = await DB.select().from(ExternalRooms).where(eq(ExternalRooms.id, input.roomId)).limit(1)
    expect(rooms[0]).toMatchObject({ id: input.roomId })

    const messages = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, input.roomId), eq(ExternalMessages.messageId, input.messageId)))
      .limit(1)

    expect(messages[0]).toMatchObject({
      roomId: input.roomId,
      messageId: input.messageId,
      authorId: input.authorId,
      text: input.text
    })
    expect(messages[0]!.mentions.length > 0).toBe(input.mentions)
  })
}

async function assertNoProjectedMessage(roomId: string, messageId: string): Promise<void> {
  await eventually(async () => {
    const messages = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, messageId)))
      .limit(1)

    expect(messages).toEqual([])
  })
}

async function assertAgentEventDone(agentUid: string, type: string, deliveryMode: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select()
      .from(ExternalGatewayAgentEvents)
      .where(
        and(
          eq(ExternalGatewayAgentEvents.agentUid, agentUid),
          eq(ExternalGatewayAgentEvents.type, type),
          eq(ExternalGatewayAgentEvents.deliveryMode, deliveryMode)
        )
      )
    expect(rows.some(row => row.status === 'done')).toBe(true)
  })
}

async function assertOutboxSent(agentUid: string, providerMessageId: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, agentUid),
          eq(ExternalGatewayOutbox.providerMessageId, providerMessageId)
        )
      )
    expect(rows.some(row => row.status === 'sent')).toBe(true)
  })
}

async function assertOutboxOperationStatus(agentUid: string, operation: string, status: string): Promise<void> {
  await eventually(async () => {
    const rows = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(and(eq(ExternalGatewayOutbox.agentUid, agentUid), eq(ExternalGatewayOutbox.operation, operation)))
    expect(rows.some(row => row.status === status)).toBe(true)
  })
}

async function assertProjectedMessageText(roomId: string, messageId: string, text: string): Promise<void> {
  await eventually(async () => {
    const messages = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, messageId)))
      .limit(1)
    expect(messages[0]?.text).toBe(text)
  })
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
