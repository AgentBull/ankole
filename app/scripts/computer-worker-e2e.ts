import 'reflect-metadata'
import assert from 'node:assert/strict'
import {
  fauxAssistantMessage,
  fauxToolCall,
  registerFauxProvider,
  type FauxProviderRegistration
} from '@earendil-works/pi-ai'
import { eq } from 'drizzle-orm'
import type { AiAgentRuntimeProfile } from '../src/ai-agent/config'
import type {
  MockImConversationOptions,
  MockImPlatform as MockImPlatformInstance
} from '../src/external-gateway/testing/mock-im-adapter'

const { loadTestEnvFiles } = await import('../src/common/tests/load-test-env')
await loadTestEnvFiles()

const { DB, closeDatabase } = await import('@/common/database')
const {
  AiAgentConversations,
  AiAgentLlmTurns,
  AiAgentMessages,
  ComputerAgentWorkerBindings,
  ComputerAgentWorkerPins,
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  ExternalGatewayOutbox,
  ExternalRooms,
  Principals
} = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const { ExternalGatewayRuntime } = await import('@/external-gateway/runtime')
const { registerExternalGatewayAdapterFactory } = await import('@/external-gateway/adapter-registry')
const { fullMockImCapabilities, MockImPlatform: MockImPlatformCtor } =
  await import('@/external-gateway/testing/mock-im-adapter')
const { AiAgentRuntime } = await import('@/ai-agent/runtime')
const { registerWorker, resolveComputerWorker } = await import('@/computer/service')
const { loadSystemTimezone } = await import('@/config/system')

const workerId = Bun.env.BULLX_COMPUTER_E2E_WORKER_ID ?? 'dev'
const workerBaseUrl = (
  Bun.env.BULLX_COMPUTER_E2E_WORKER_URL ?? `http://localhost:${Bun.env.BULLX_COMPUTER_PORT ?? '8787'}`
).replace(/\/$/, '')
const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentUid = `computer_e2e_${suffix}`
const adapterName = `mock_computer_e2e_${suffix}`
const factoryId = `computer_e2e_factory_${suffix}`
const roomIds = new Set<string>()
let runtime: InstanceType<typeof ExternalGatewayRuntime> | undefined
let aiRuntime: InstanceType<typeof AiAgentRuntime> | undefined
let registration: FauxProviderRegistration | undefined

try {
  await requireDevWorker(workerBaseUrl)
  await registerWorker({
    workerId,
    instanceId: `${workerId}-e2e`,
    baseUrl: workerBaseUrl,
    features: ['bwrap', 'persistent-shell', 'tmux'],
    capacity: { maxAgents: 128, maxCommands: 32 },
    metadata: { source: 'computer-worker-e2e' }
  })

  const platform: MockImPlatformInstance = new MockImPlatformCtor()
  registration = registerFauxProvider({
    provider: `computer_e2e_provider_${suffix}`,
    models: [
      { id: 'primary', contextWindow: 2048 },
      { id: 'light', contextWindow: 2048 },
      { id: 'heavy', contextWindow: 2048 }
    ]
  })
  registration.setResponses([
    fauxAssistantMessage([
      fauxToolCall('command', {
        command:
          'python3 -c \'import os, pathlib; uid=os.environ["BULLX_AGENT_UID"]; p=pathlib.Path("user-files/e2e-command.txt"); p.parent.mkdir(parents=True, exist_ok=True); p.write_text("computer-e2e:" + uid); print(p.read_text())\'',
        timeout: 10
      })
    ]),
    fauxAssistantMessage('computer command finished')
  ])

  registerExternalGatewayAdapterFactory({
    id: factoryId,
    create: context =>
      platform.createAdapter(context.channel.name, {
        capabilities: fullMockImCapabilities,
        groupMessageMode: 'observe_all'
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

  aiRuntime = new AiAgentRuntime({
    loadProfile: async () => runtimeProfile(registration!)
  })
  aiRuntime.setComputerEnabled(true, { resolveWorker: uid => resolveComputerWorker(uid) })

  runtime = new ExternalGatewayRuntime()
  await runtime.start({
    agentExecutor: aiRuntime,
    getChannelConfig: async () => ({ group_message_mode: 'observe_all' }),
    loadActiveAgents: async () => [agent]
  })

  const dm = platform.dm(conversationOptions(runtime, agentUid, adapterName))
  roomIds.add(dm.channelId)
  await dm.say({ id: 'm1', text: '@Agent run a python command in your computer' })

  await eventually(() => {
    assert.equal(
      platform.outbound.some(event => event.op === 'post' && event.text === 'computer command finished'),
      true
    )
  }, 20_000)

  const [binding] = await DB.select()
    .from(ComputerAgentWorkerBindings)
    .where(eq(ComputerAgentWorkerBindings.agentUid, agentUid))
    .limit(1)
  assert.equal(binding?.workerId, workerId)

  const [conversation] = await DB.select()
    .from(AiAgentConversations)
    .where(eq(AiAgentConversations.agentUid, agentUid))
    .limit(1)
  assert.ok(conversation, 'expected ai-agent conversation to be persisted')
  const turns = await DB.select().from(AiAgentLlmTurns).where(eq(AiAgentLlmTurns.conversationId, conversation.id))
  const serializedToolResults = JSON.stringify(turns.flatMap(turn => turn.toolResults ?? []))
  assert.match(serializedToolResults, /exit_code=0/)
  assert.equal(serializedToolResults.includes(`computer-e2e:${agentUid}`), true)

  // oxlint-disable-next-line no-console
  console.log(`OK computer worker e2e passed: agent=${agentUid} worker=${workerId} url=${workerBaseUrl}`)
} finally {
  await runtime?.stop()
  aiRuntime?.stop()
  registration?.unregister()
  await cleanup()
  await closeDatabase({ timeout: 5 }).catch(() => undefined)
}

function conversationOptions(
  currentRuntime: InstanceType<typeof ExternalGatewayRuntime>,
  currentAgentUid: string,
  currentAdapterName: string
): MockImConversationOptions {
  const channelId = `${currentAdapterName}:dm`
  roomIds.add(channelId)
  return {
    adapterName: currentAdapterName,
    agentUid: currentAgentUid,
    channelId,
    channelName: currentAdapterName,
    deliver: currentRuntime.handleWebhook.bind(currentRuntime),
    mode: 'observe_all',
    threadId: `${channelId}:thread`
  }
}

async function runtimeProfile(currentRegistration: FauxProviderRegistration): Promise<AiAgentRuntimeProfile> {
  const primary = currentRegistration.getModel('primary')!
  const light = currentRegistration.getModel('light')!
  const heavy = currentRegistration.getModel('heavy')!
  const timezone = await loadSystemTimezone()
  return {
    ambient: { batchWindowMs: 20, freshnessMs: 5_000 },
    compression: {
      enabled: true,
      keepRecentTokens: 20_000,
      maxOverflowRetries: 1,
      reserveTokens: 0,
      microcompactEnabled: false,
      microcompactKeepRecent: 6
    },
    dailyReset: { enabled: true, hour: '00:00', retryMinutes: 30, timezone },
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

async function requireDevWorker(baseUrl: string): Promise<void> {
  let response: Response
  try {
    response = await fetch(`${baseUrl}/healthz`, { signal: AbortSignal.timeout(3_000) })
  } catch (error) {
    throw new Error(
      `Computer worker is not reachable at ${baseUrl}. Start it with "bun run services:start" before running this script.`,
      { cause: error }
    )
  }
  if (!response.ok) {
    throw new Error(`Computer worker health check failed at ${baseUrl}/healthz: HTTP ${response.status}`)
  }
}

async function cleanup(): Promise<void> {
  await DB.delete(ComputerAgentWorkerBindings).where(eq(ComputerAgentWorkerBindings.agentUid, agentUid))
  await DB.delete(ComputerAgentWorkerPins).where(eq(ComputerAgentWorkerPins.agentUid, agentUid))
  await DB.delete(AiAgentLlmTurns).where(eq(AiAgentLlmTurns.agentUid, agentUid))
  await DB.delete(AiAgentMessages).where(eq(AiAgentMessages.agentUid, agentUid))
  await DB.delete(AiAgentConversations).where(eq(AiAgentConversations.agentUid, agentUid))
  await DB.delete(ExternalGatewayOutbox).where(eq(ExternalGatewayOutbox.agentUid, agentUid))
  await DB.delete(ExternalGatewayAgentEvents).where(eq(ExternalGatewayAgentEvents.agentUid, agentUid))
  await DB.delete(ExternalGatewayInputTombstones).where(eq(ExternalGatewayInputTombstones.agentUid, agentUid))
  for (const roomId of roomIds) await DB.delete(ExternalRooms).where(eq(ExternalRooms.id, roomId))
  await DB.delete(Principals).where(eq(Principals.uid, agentUid))
}

async function eventually(assertion: () => void | Promise<void>, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  let lastError: unknown
  while (Date.now() < deadline) {
    try {
      await assertion()
      return
    } catch (error) {
      lastError = error
      await Bun.sleep(50)
    }
  }
  try {
    await assertion()
  } catch (error) {
    throw lastError ?? error
  }
}
