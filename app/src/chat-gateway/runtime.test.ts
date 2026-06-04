import 'reflect-metadata'
import { afterAll, describe, expect, it } from 'bun:test'
import { Message, type Adapter, type ChatInstance, type WebhookOptions } from 'chat'
import { eq } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { AppConfigure, ChatStateCache, ChatStateLists, ChatStateLocks, ChatStateQueues, ChatStateSubscriptions } =
  await import('@/common/db-schema')
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

afterAll(async () => {
  for (const key of dynamicConfigKeys) await DB.delete(AppConfigure).where(eq(AppConfigure.key, key))

  for (const keyPrefix of runtimeStatePrefixes) await cleanupStateRows(keyPrefix)

  for (const uid of createdAgentUids) await DB.delete(Principals).where(eq(Principals.uid, uid))
})

describe('ChatGatewayRuntime', () => {
  it('loads active agent channel metadata, initializes chat, and handles webhooks', async () => {
    const adapter = new FakeChatAdapter('fake')
    const factoryId = `${factoryPrefix}_factory`
    const agentUid = `${testPrefix}-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    runtimeStatePrefixes.add(statePrefix)

    registerChatGatewayAdapterFactory({
      id: factoryId,
      create: context => {
        expect(context.agent.agent.uid).toBe(agentUid)
        expect(context.channel.name).toBe('fake')
        expect(context.config).toEqual({ token: 'configured' })
        expect(typeof context.projection.projectMessage).toBe('function')
        expect(typeof context.projection.projectDelete).toBe('function')
        expect(typeof context.projection.projectReaction).toBe('function')
        expect(typeof context.externalIdentities.upsertPlatformSubject).toBe('function')
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

  it('uses Chat SDK routing so new mentions subscribe and follow-up messages echo', async () => {
    const adapter = new FakeChatAdapter('fake_echo')
    const factoryId = `${factoryPrefix}_echo_factory`
    const agentUid = `${testPrefix}-echo-agent`.toLowerCase()
    const statePrefix = `bullx-agent:${agentUid}`
    runtimeStatePrefixes.add(statePrefix)

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

    await runtime.handleWebhook(
      agentUid,
      'fake_echo',
      jsonRequest({
        id: 'follow-up-1',
        threadId: 'fake_echo:channel:thread-2',
        text: 'follow up'
      })
    )
    await eventually(() => expect(adapter.posts).toHaveLength(2))
    expect(adapter.posts[1]?.text).toBe(`[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]\n\nfollow up`)

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
  id?: string
  isMention?: boolean
  text?: string
  threadId?: string
}

class FakeChatAdapter implements Adapter<string, FakeWebhookPayload> {
  readonly userName = 'Agent'
  chat: ChatInstance | undefined
  initialized = 0
  posts: Array<{ text: string; threadId: string }> = []

  constructor(readonly name: string) {}

  async initialize(chat: ChatInstance): Promise<void> {
    this.chat = chat
    this.initialized += 1
  }

  async disconnect(): Promise<void> {}

  async handleWebhook(request: Request, _options?: WebhookOptions): Promise<Response> {
    const payload = (await request.json()) as FakeWebhookPayload
    await this.chat?.processMessage(
      this,
      payload.threadId ?? `${this.name}:channel:default-thread`,
      this.parseMessage(payload)
    )
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
    this.posts.push({ threadId, text })
    return {
      id: `${this.name}-post-${this.posts.length}`,
      threadId,
      raw: { text }
    }
  }

  async editMessage(threadId: string, messageId: string, message: unknown) {
    return {
      id: messageId,
      threadId,
      raw: { text: postableText(message) }
    }
  }

  async deleteMessage(): Promise<void> {}

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
