import 'reflect-metadata'
import { afterAll, describe, expect, it } from 'bun:test'
import { Message } from './core/message'
import type { Adapter, ChatInstance, WebhookOptions } from './core/types'
import { and, eq } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const {
  AppConfigure,
  ChatChannels,
  ChatMessages,
  ChatStateCache,
  ChatStateLists,
  ChatStateLocks,
  ChatStateQueues,
  ChatStateSubscriptions
} = await import('@/common/db-schema')
const { Principals } = await import('@/common/db-schema/principals')
const { createAgent } = await import('@/principals/agents/service')
const { ChatGatewayRuntime } = await import('./runtime')
const { registerChatGatewayAdapterFactory, MissingChatGatewayAdapterFactoryError } = await import('./adapter-registry')
const { chatGatewayRoutes } = await import('./routes')
const { PluginRuntime } = await import('@/plugins/runtime')
const { defineBullXPlugin } = await import('@agentbull/bullx-sdk/plugins')

const testPrefix = `__test-chat-gateway-${Date.now()}-${Math.random().toString(36).slice(2)}`
const factoryPrefix = `test_${Date.now()}_${Math.random().toString(36).slice(2)}`
const createdAgentUids = new Set<string>()
const runtimeStatePrefixes = new Set<string>()
const dynamicConfigKeys = new Set<string>()
const projectedChannelIds = new Set<string>()

afterAll(async () => {
  for (const key of dynamicConfigKeys) await DB.delete(AppConfigure).where(eq(AppConfigure.key, key))

  for (const keyPrefix of runtimeStatePrefixes) await cleanupStateRows(keyPrefix)

  for (const channelId of projectedChannelIds) await DB.delete(ChatChannels).where(eq(ChatChannels.id, channelId))

  for (const uid of createdAgentUids) await DB.delete(Principals).where(eq(Principals.uid, uid))
})

describe('ChatGatewayRuntime', () => {
  it('loads active agent channel metadata, initializes chat, and handles webhooks', async () => {
    const adapter = new FakeChatAdapter('fake')
    const factoryId = `${factoryPrefix}_factory`
    const agentUid = `${testPrefix}-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: context => {
        expect(context.agent.agent.uid).toBe(agentUid)
        expect(context.channel.name).toBe('fake')
        expect(context.config).toEqual({ token: 'configured' })
        expect(typeof context.externalIdentities.upsertPlatformSubject).toBe('function')
        expect('core' in context).toBe(false)
        expect('projection' in context).toBe(false)
        expect('messageLifecycle' in context).toBe(false)
        return adapter
      }
    })

    const runtime = new ChatGatewayRuntime()
    const stats = await runtime.start({
      loadActiveAgents: async () => [
        agentResult(agentUid, [
          { name: 'fake', adapter: factoryId },
          { name: 'disabled_fake', adapter: factoryId, enabled: false }
        ]),
        agentResult(`${testPrefix}-no-channels`, [])
      ],
      getChannelConfig: async key => {
        dynamicConfigKeys.add(key)
        return { token: 'configured' }
      }
    })

    expect(stats).toEqual({ readyAgents: 1, readyChannels: 1 })
    expect(adapter.initialized).toBe(1)

    const response = await runtime.handleWebhook(
      agentUid.toUpperCase(),
      'fake',
      jsonRequest({
        id: 'mention-1',
        threadId: 'fake:channel:thread-1',
        text: '@Agent hello',
        isMention: true
      })
    )

    expect(response.status).toBe(200)
    await eventually(() => expect(adapter.posts).toHaveLength(1))
    expect(adapter.posts[0]).toEqual({
      threadId: 'fake:channel:thread-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent hello`
    })
    await assertProjectedMessage({
      channelId,
      threadId: 'fake:channel:thread-1',
      messageId: 'mention-1',
      text: '@Agent hello'
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake:channel:thread-1',
      messageId: 'fake-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent hello`
    })

    expect((await runtime.handleWebhook('missing-agent', 'fake', jsonRequest())).status).toBe(404)
    expect((await runtime.handleWebhook(agentUid, 'missing_channel', jsonRequest())).status).toBe(404)

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('fails startup when an enabled channel references an unregistered factory', async () => {
    const runtime = new ChatGatewayRuntime()

    await expect(
      runtime.start({
        loadActiveAgents: async () => [
          agentResult(`${testPrefix}-missing-factory`, [{ name: 'fake', adapter: `${factoryPrefix}_missing` }])
        ]
      })
    ).rejects.toThrow(MissingChatGatewayAdapterFactoryError)
  })

  it('uses adapter factories registered by enabled trusted plugins', async () => {
    const adapter = new FakeChatAdapter('plugin_fake')
    const pluginId = `${factoryPrefix}-plugin`.replaceAll('_', '-')
    const factoryId = `${factoryPrefix}_plugin_factory`
    const agentUid = `${testPrefix}-plugin-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    runtimeStatePrefixes.add(statePrefix)

    const pluginRuntime = new PluginRuntime()
    await pluginRuntime.start({
      plugins: [
        defineBullXPlugin({
          metadata: {
            id: pluginId,
            apiVersion: 1
          },
          chatGatewayAdapters: [
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

    const runtime = new ChatGatewayRuntime()
    const stats = await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'plugin_fake', adapter: factoryId }])]
    })

    expect(stats).toEqual({ readyAgents: 1, readyChannels: 1 })
    expect(adapter.initialized).toBe(1)

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('treats subscribed group follow-ups as ambient observations without replying', async () => {
    const adapter = new FakeChatAdapter('fake_echo')
    const factoryId = `${factoryPrefix}_echo_factory`
    const agentUid = `${testPrefix}-echo-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_echo:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_echo', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_echo',
      jsonRequest({
        id: 'mention-1',
        threadId: 'fake_echo:channel:thread-2',
        text: '@Agent start',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_echo:channel:thread-2',
      messageId: 'mention-1',
      text: '@Agent start'
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_echo',
      jsonRequest({
        id: 'follow-up-1',
        threadId: 'fake_echo:channel:thread-2',
        text: 'follow up'
      })
    )
    await Bun.sleep(100)
    expect(adapter.posts).toHaveLength(1)
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_echo:channel:thread-2',
      messageId: 'follow-up-1',
      text: 'follow up'
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_echo',
      jsonRequest({
        id: 'literal-at-1',
        threadId: 'fake_echo:channel:thread-2',
        text: '@Agent typed as plain text',
        isMention: false
      })
    )
    await Bun.sleep(100)
    expect(adapter.posts).toHaveLength(1)
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_echo:channel:thread-2',
      messageId: 'literal-at-1',
      text: '@Agent typed as plain text',
      isMention: false
    })

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('engages when an ambient or previously unseen group message is edited into an addressed message', async () => {
    const adapter = new FakeChatAdapter('fake_edit_addressing')
    const factoryId = `${factoryPrefix}_edit_addressing_factory`
    const agentUid = `${testPrefix}-edit-addressing-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_edit_addressing:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_edit_addressing', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_edit_addressing',
      jsonRequest({
        id: 'ambient-then-addressed',
        threadId: 'fake_edit_addressing:channel:thread-1',
        text: 'can you look at the logs',
        isMention: false
      })
    )
    await Bun.sleep(100)
    expect(adapter.posts).toHaveLength(0)
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_edit_addressing:channel:thread-1',
      messageId: 'ambient-then-addressed',
      text: 'can you look at the logs',
      isMention: false
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_edit_addressing',
      jsonRequest({
        event: 'edit',
        id: 'ambient-then-addressed',
        threadId: 'fake_edit_addressing:channel:thread-1',
        text: '@Agent can you look at the logs',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_edit_addressing:channel:thread-1',
      messageId: 'ambient-then-addressed',
      text: '@Agent can you look at the logs',
      isMention: true
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_edit_addressing:channel:thread-1',
      messageId: 'fake_edit_addressing-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent can you look at the logs`
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_edit_addressing',
      jsonRequest({
        event: 'edit',
        id: 'unseen-then-addressed',
        threadId: 'fake_edit_addressing:channel:thread-2',
        text: '@Agent this edit is the first delivered event',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(2))
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_edit_addressing:channel:thread-2',
      messageId: 'unseen-then-addressed',
      text: '@Agent this edit is the first delivered event',
      isMention: true
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_edit_addressing:channel:thread-2',
      messageId: 'fake_edit_addressing-post-2',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent this edit is the first delivered event`
    })

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('retries reply creation when an existing ambient message is edited into addressed after post failure', async () => {
    const adapter = new FakeChatAdapter('fake_create_retry')
    const factoryId = `${factoryPrefix}_create_retry_factory`
    const agentUid = `${testPrefix}-create-retry-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_create_retry:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_create_retry', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_create_retry',
      jsonRequest({
        id: 'create-retry-1',
        threadId: 'fake_create_retry:channel:thread-1',
        text: 'please inspect later',
        isMention: false
      })
    )
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_create_retry:channel:thread-1',
      messageId: 'create-retry-1',
      text: 'please inspect later',
      isMention: false
    })

    adapter.postFailures = 1
    const addressedEditPayload = {
      event: 'edit',
      id: 'create-retry-1',
      threadId: 'fake_create_retry:channel:thread-1',
      text: '@Agent please inspect later',
      isMention: true
    } satisfies FakeWebhookPayload
    await expect(runtime.handleWebhook(agentUid, 'fake_create_retry', jsonRequest(addressedEditPayload))).rejects.toThrow(
      'simulated post failure'
    )
    expect(adapter.posts).toHaveLength(0)
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_create_retry:channel:thread-1',
      messageId: 'create-retry-1',
      text: '@Agent please inspect later',
      isMention: true
    })

    await runtime.handleWebhook(agentUid, 'fake_create_retry', jsonRequest(addressedEditPayload))
    await eventually(() => expect(adapter.posts).toHaveLength(1))
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_create_retry:channel:thread-1',
      messageId: 'fake_create_retry-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent please inspect later`
    })

    await runtime.handleWebhook(agentUid, 'fake_create_retry', jsonRequest(addressedEditPayload))
    await Bun.sleep(100)
    expect(adapter.posts).toHaveLength(1)

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('updates and recalls BullX replies for inbound message lifecycle events', async () => {
    const adapter = new FakeChatAdapter('fake_lifecycle')
    const factoryId = `${factoryPrefix}_lifecycle_factory`
    const agentUid = `${testPrefix}-lifecycle-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_lifecycle:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_lifecycle', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_lifecycle',
      jsonRequest({
        id: 'editable-1',
        threadId: 'fake_lifecycle:channel:thread-1',
        text: '@Agent before',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_lifecycle:channel:thread-1',
      messageId: 'fake_lifecycle-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent before`
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_lifecycle',
      jsonRequest({
        event: 'edit',
        id: 'editable-1',
        threadId: 'fake_lifecycle:channel:thread-1',
        text: '@Agent after',
        isMention: true
      })
    )
    await eventually(() =>
      expect(adapter.edits[0]).toEqual({
        threadId: 'fake_lifecycle:channel:thread-1',
        messageId: 'fake_lifecycle-post-1',
        text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent after`
      })
    )
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_lifecycle:channel:thread-1',
      messageId: 'editable-1',
      text: '@Agent after',
      isMention: true
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_lifecycle:channel:thread-1',
      messageId: 'fake_lifecycle-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent after`,
      edited: true
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_lifecycle',
      jsonRequest({
        event: 'delete',
        id: 'editable-1',
        threadId: 'fake_lifecycle:channel:thread-1'
      })
    )
    await eventually(() =>
      expect(adapter.deletes[0]).toEqual({
        threadId: 'fake_lifecycle:channel:thread-1',
        messageId: 'fake_lifecycle-post-1'
      })
    )
    await eventually(async () => {
      const messages = await DB.select()
        .from(ChatMessages)
        .where(and(eq(ChatMessages.channelId, channelId), eq(ChatMessages.messageId, 'editable-1')))
      expect(messages).toEqual([])
    })
    await assertNoProjectedMessage(channelId, 'fake_lifecycle-post-1')

    await runtime.handleWebhook(
      agentUid,
      'fake_lifecycle',
      jsonRequest({
        id: 'editable-1',
        threadId: 'fake_lifecycle:channel:thread-1',
        text: '@Agent stale receive',
        isMention: true
      })
    )
    await Bun.sleep(100)
    expect(adapter.posts).toHaveLength(1)

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('keeps addressed edit reply updates retryable when the external edit fails', async () => {
    const adapter = new FakeChatAdapter('fake_retry_edit')
    const factoryId = `${factoryPrefix}_retry_edit_factory`
    const agentUid = `${testPrefix}-retry-edit-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_retry_edit:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_retry_edit', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_retry_edit',
      jsonRequest({
        id: 'retry-edit-1',
        threadId: 'fake_retry_edit:channel:thread-1',
        text: '@Agent before',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))

    adapter.editFailures = 1
    await expect(
      runtime.handleWebhook(
        agentUid,
        'fake_retry_edit',
        jsonRequest({
          event: 'edit',
          id: 'retry-edit-1',
          threadId: 'fake_retry_edit:channel:thread-1',
          text: '@Agent after',
          isMention: true
        })
      )
    ).rejects.toThrow('simulated edit failure')
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_retry_edit:channel:thread-1',
      messageId: 'retry-edit-1',
      text: '@Agent after',
      isMention: true
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_retry_edit:channel:thread-1',
      messageId: 'fake_retry_edit-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent before`
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_retry_edit',
      jsonRequest({
        event: 'edit',
        id: 'retry-edit-1',
        threadId: 'fake_retry_edit:channel:thread-1',
        text: '@Agent after',
        isMention: true
      })
    )

    await eventually(() => expect(adapter.edits).toHaveLength(2))
    expect(adapter.edits[0]).toEqual(adapter.edits[1])
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_retry_edit:channel:thread-1',
      messageId: 'retry-edit-1',
      text: '@Agent after',
      isMention: true
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_retry_edit:channel:thread-1',
      messageId: 'fake_retry_edit-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent after`,
      edited: true
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_retry_edit',
      jsonRequest({
        event: 'edit',
        id: 'retry-edit-1',
        threadId: 'fake_retry_edit:channel:thread-1',
        text: '@Agent after',
        isMention: true
      })
    )
    await Bun.sleep(100)
    expect(adapter.edits).toHaveLength(2)

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('recalls the previous BullX reply when an addressed group message is edited into ambient', async () => {
    const adapter = new FakeChatAdapter('fake_downgrade')
    const factoryId = `${factoryPrefix}_downgrade_factory`
    const agentUid = `${testPrefix}-downgrade-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_downgrade:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_downgrade', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_downgrade',
      jsonRequest({
        id: 'downgraded-1',
        threadId: 'fake_downgrade:channel:thread-1',
        text: '@Agent summarize this',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))

    adapter.deleteFailures = 1
    const downgradeEdit = jsonRequest({
      event: 'edit',
      id: 'downgraded-1',
      threadId: 'fake_downgrade:channel:thread-1',
      text: 'summarize this',
      isMention: false
    })
    await expect(runtime.handleWebhook(agentUid, 'fake_downgrade', downgradeEdit)).rejects.toThrow(
      'simulated delete failure'
    )
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_downgrade:channel:thread-1',
      messageId: 'downgraded-1',
      text: 'summarize this',
      isMention: false
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_downgrade:channel:thread-1',
      messageId: 'fake_downgrade-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent summarize this`
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_downgrade',
      jsonRequest({
        event: 'edit',
        id: 'downgraded-1',
        threadId: 'fake_downgrade:channel:thread-1',
        text: 'summarize this',
        isMention: false
      })
    )

    await eventually(() =>
      expect(adapter.deletes[1]).toEqual({
        threadId: 'fake_downgrade:channel:thread-1',
        messageId: 'fake_downgrade-post-1'
      })
    )
    expect(adapter.deletes[0]).toEqual(adapter.deletes[1])
    expect(adapter.posts).toHaveLength(1)
    expect(adapter.edits).toEqual([])
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_downgrade:channel:thread-1',
      messageId: 'downgraded-1',
      text: 'summarize this',
      isMention: false
    })
    await assertNoProjectedMessage(channelId, 'fake_downgrade-post-1')

    await runtime.handleWebhook(
      agentUid,
      'fake_downgrade',
      jsonRequest({
        event: 'edit',
        id: 'downgraded-1',
        threadId: 'fake_downgrade:channel:thread-1',
        text: 'summarize this',
        isMention: false
      })
    )
    await Bun.sleep(100)
    expect(adapter.deletes).toHaveLength(2)

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('keeps a visible BullX reply projected when the channel cannot delete replies', async () => {
    const adapter = new FakeChatAdapter('fake_no_delete', capabilitiesWithout('outbound', 'delete_message'))
    const factoryId = `${factoryPrefix}_no_delete_factory`
    const agentUid = `${testPrefix}-no-delete-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_no_delete:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_no_delete', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_no_delete',
      jsonRequest({
        id: 'no-delete-1',
        threadId: 'fake_no_delete:channel:thread-1',
        text: '@Agent investigate',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))

    await runtime.handleWebhook(
      agentUid,
      'fake_no_delete',
      jsonRequest({
        event: 'edit',
        id: 'no-delete-1',
        threadId: 'fake_no_delete:channel:thread-1',
        text: 'investigate',
        isMention: false
      })
    )
    await Bun.sleep(100)

    expect(adapter.deletes).toEqual([])
    await assertProjectedMessage({
      channelId,
      threadId: 'fake_no_delete:channel:thread-1',
      messageId: 'no-delete-1',
      text: 'investigate',
      isMention: false
    })
    await assertProjectedBotMessage({
      channelId,
      threadId: 'fake_no_delete:channel:thread-1',
      messageId: 'fake_no_delete-post-1',
      text: `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\n@Agent investigate`
    })

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('projects metadata-only edit lifecycle events without rewriting the BullX reply', async () => {
    const adapter = new FakeChatAdapter('fake_metadata_edit')
    const factoryId = `${factoryPrefix}_metadata_edit_factory`
    const agentUid = `${testPrefix}-metadata-edit-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_metadata_edit:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_metadata_edit', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_metadata_edit',
      jsonRequest({
        id: 'metadata-edit-1',
        threadId: 'fake_metadata_edit:channel:thread-1',
        text: '@Agent same text',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))

    await runtime.handleWebhook(
      agentUid,
      'fake_metadata_edit',
      jsonRequest({
        event: 'edit',
        id: 'metadata-edit-1',
        threadId: 'fake_metadata_edit:channel:thread-1',
        text: '@Agent same text',
        isMention: true
      })
    )

    await eventually(async () => {
      const rows = await DB.select()
        .from(ChatMessages)
        .where(and(eq(ChatMessages.channelId, channelId), eq(ChatMessages.messageId, 'metadata-edit-1')))
        .limit(1)

      expect(rows[0]?.editedAt).toBeInstanceOf(Date)
    })
    expect(adapter.edits).toEqual([])

    await runtime.stop()
    await cleanupStateRows(statePrefix)
  })

  it('keeps reply links retryable when external reply recall fails', async () => {
    const adapter = new FakeChatAdapter('fake_retry_delete')
    const factoryId = `${factoryPrefix}_retry_delete_factory`
    const agentUid = `${testPrefix}-retry-delete-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    const channelId = 'fake_retry_delete:channel'
    runtimeStatePrefixes.add(statePrefix)
    projectedChannelIds.add(channelId)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: () => adapter
    })

    const runtime = new ChatGatewayRuntime()
    await runtime.start({
      loadActiveAgents: async () => [agentResult(agentUid, [{ name: 'fake_retry_delete', adapter: factoryId }])]
    })

    await runtime.handleWebhook(
      agentUid,
      'fake_retry_delete',
      jsonRequest({
        id: 'retry-delete-1',
        threadId: 'fake_retry_delete:channel:thread-1',
        text: '@Agent delete me',
        isMention: true
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(1))

    adapter.deleteFailures = 1
    await expect(
      runtime.handleWebhook(
        agentUid,
        'fake_retry_delete',
        jsonRequest({
          event: 'delete',
          id: 'retry-delete-1',
          threadId: 'fake_retry_delete:channel:thread-1'
        })
      )
    ).rejects.toThrow('simulated delete failure')

    await runtime.handleWebhook(
      agentUid,
      'fake_retry_delete',
      jsonRequest({
        event: 'delete',
        id: 'retry-delete-1',
        threadId: 'fake_retry_delete:channel:thread-1'
      })
    )

    await eventually(() => expect(adapter.deletes).toHaveLength(2))
    expect(adapter.deletes[0]).toEqual(adapter.deletes[1])
    await assertNoProjectedMessage(channelId, 'fake_retry_delete-post-1')

    await runtime.stop()
    await cleanupStateRows(statePrefix)
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

describe('chatGatewayRoutes', () => {
  it('binds POST /api/agents/:agentUid/webhooks/:channel to runtime.handleWebhook', async () => {
    const calls: Array<{ agentUid: string; channel: string; method: string }> = []
    const app = chatGatewayRoutes({
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
  event?: 'delete' | 'edit'
  id?: string
  isMention?: boolean
  text?: string
  threadId?: string
}

const defaultFakeCapabilities = {
  inbound: ['message_receive', 'message_edit', 'message_recall', 'reaction_add', 'reaction_remove'],
  outbound: ['post_message', 'edit_message', 'delete_message', 'add_reaction', 'remove_reaction'],
  history: ['fetch_thread_messages']
} as const satisfies Adapter['capabilities']

function capabilitiesWithout(
  section: keyof NonNullable<Adapter['capabilities']>,
  capability: string
): Adapter['capabilities'] {
  const source = defaultFakeCapabilities
  return {
    inbound: [...source.inbound],
    outbound: [...source.outbound],
    history: [...source.history],
    [section]: [...(source[section] ?? [])].filter(item => item !== capability)
  } as Adapter['capabilities']
}

class FakeChatAdapter implements Adapter<string, FakeWebhookPayload> {
  readonly userName = 'Agent'
  readonly capabilities: Adapter['capabilities']
  chat: ChatInstance | undefined
  initialized = 0
  deletes: Array<{ messageId: string; threadId: string }> = []
  deleteFailures = 0
  edits: Array<{ messageId: string; text: string; threadId: string }> = []
  editFailures = 0
  postFailures = 0
  posts: Array<{ text: string; threadId: string }> = []

  constructor(readonly name: string, capabilities: Adapter['capabilities'] = defaultFakeCapabilities) {
    this.capabilities = capabilities
  }

  async initialize(chat: ChatInstance): Promise<void> {
    this.chat = chat
    this.initialized += 1
  }

  async disconnect(): Promise<void> {}

  async handleWebhook(request: Request, _options?: WebhookOptions): Promise<Response> {
    const payload = (await request.json()) as FakeWebhookPayload
    const threadId = payload.threadId ?? `${this.name}:channel:default-thread`
    if (payload.event === 'edit') {
      await this.chat?.processMessageEdited({
        adapter: this,
        threadId,
        messageId: payload.id ?? crypto.randomUUID(),
        message: this.parseMessage(payload),
        raw: payload,
        editedAt: new Date()
      })
      return Response.json({ ok: true })
    }

    if (payload.event === 'delete') {
      await this.chat?.processMessageDeleted({
        adapter: this,
        threadId,
        messageId: payload.id ?? crypto.randomUUID(),
        raw: payload,
        deletedAt: new Date(),
        kind: 'recalled'
      })
      return Response.json({ ok: true })
    }

    await this.chat?.processMessage(this, threadId, this.parseMessage(payload))
    return Response.json({ ok: true })
  }

  parseMessage(raw: FakeWebhookPayload): Message<FakeWebhookPayload> {
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

  async fetchMessages() {
    return { messages: [] }
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
    const text = postableText(message)
    if (this.postFailures > 0) {
      this.postFailures -= 1
      throw new Error('simulated post failure')
    }

    this.posts.push({ threadId, text })
    return {
      id: `${this.name}-post-${this.posts.length}`,
      threadId,
      raw: { text }
    }
  }

  async editMessage(threadId: string, messageId: string, message: unknown) {
    const text = postableText(message)
    this.edits.push({ threadId, messageId, text })
    if (this.editFailures > 0) {
      this.editFailures -= 1
      throw new Error('simulated edit failure')
    }

    return {
      id: messageId,
      threadId,
      raw: { text }
    }
  }

  async deleteMessage(threadId: string, messageId: string): Promise<void> {
    this.deletes.push({ threadId, messageId })
    if (this.deleteFailures > 0) {
      this.deleteFailures -= 1
      throw new Error('simulated delete failure')
    }
  }

  async addReaction(): Promise<void> {}

  async removeReaction(): Promise<void> {}

  async startTyping(): Promise<void> {}

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

function messageFromPayload(adapterName: string, payload: FakeWebhookPayload): Message<FakeWebhookPayload> {
  const id = payload.id ?? crypto.randomUUID()
  const text = payload.text ?? ''

  return new Message({
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
      dateSent: new Date(),
      edited: false
    },
    attachments: [],
    isMention: payload.isMention
  })
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

function postableText(value: unknown): string {
  if (typeof value === 'string') return value

  if (typeof value === 'object' && value !== null && 'markdown' in value && typeof value.markdown === 'string') {
    return value.markdown
  }

  if (typeof value === 'object' && value !== null && 'raw' in value && typeof value.raw === 'string') return value.raw

  return JSON.stringify(value)
}

async function assertProjectedMessage(input: {
  channelId: string
  isMention?: boolean
  threadId: string
  messageId: string
  text: string
}): Promise<void> {
  await eventually(async () => {
    const channels = await DB.select().from(ChatChannels).where(eq(ChatChannels.id, input.channelId)).limit(1)
    expect(channels[0]).toMatchObject({
      id: input.channelId
    })

    const messages = await DB.select()
      .from(ChatMessages)
      .where(and(eq(ChatMessages.channelId, input.channelId), eq(ChatMessages.messageId, input.messageId)))
      .limit(1)

    const expected: Record<string, unknown> = {
      channelId: input.channelId,
      threadId: input.threadId,
      messageId: input.messageId,
      authorId: 'user-1',
      text: input.text
    }
    if (input.isMention !== undefined) expected.isMention = input.isMention

    expect(messages[0]).toMatchObject(expected)
    expect(messages[0]?.author).toMatchObject({
      userId: 'user-1'
    })
  })
}

async function assertProjectedBotMessage(input: {
  channelId: string
  edited?: boolean
  threadId: string
  messageId: string
  text: string
}): Promise<void> {
  await eventually(async () => {
    const messages = await DB.select()
      .from(ChatMessages)
      .where(and(eq(ChatMessages.channelId, input.channelId), eq(ChatMessages.messageId, input.messageId)))
      .limit(1)

    expect(messages[0]).toMatchObject({
      channelId: input.channelId,
      threadId: input.threadId,
      messageId: input.messageId,
      authorId: 'self',
      text: input.text
    })
    expect(messages[0]?.author).toMatchObject({
      isBot: true,
      isMe: true,
      userId: 'self'
    })
    if (input.edited !== undefined) expect(messages[0]?.editedAt instanceof Date).toBe(input.edited)
  })
}

async function assertNoProjectedMessage(channelId: string, messageId: string): Promise<void> {
  await eventually(async () => {
    const messages = await DB.select()
      .from(ChatMessages)
      .where(and(eq(ChatMessages.channelId, channelId), eq(ChatMessages.messageId, messageId)))
      .limit(1)

    expect(messages).toEqual([])
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

async function cleanupStateRows(keyPrefix: string) {
  await DB.delete(ChatStateSubscriptions).where(eq(ChatStateSubscriptions.keyPrefix, keyPrefix))
  await DB.delete(ChatStateLocks).where(eq(ChatStateLocks.keyPrefix, keyPrefix))
  await DB.delete(ChatStateCache).where(eq(ChatStateCache.keyPrefix, keyPrefix))
  await DB.delete(ChatStateLists).where(eq(ChatStateLists.keyPrefix, keyPrefix))
  await DB.delete(ChatStateQueues).where(eq(ChatStateQueues.keyPrefix, keyPrefix))
}
