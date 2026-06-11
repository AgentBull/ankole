import assert from 'node:assert/strict'
import { mkdir } from 'node:fs/promises'
import { redis } from 'bun'
import { compact, isPlainObject } from '@pleisto/active-support'
import { and, eq, sql } from 'drizzle-orm'
import type { AiAgentModelsConfig } from '../src/ai-agent/config'
import type {
  MockImConversationOptions,
  MockImPlatform as MockImPlatformInstance
} from '../src/external-gateway/testing/mock-im-adapter'
import type { WebProvider, WebSearchArgs, WebExtractArgs } from '../src/ai-agent/web/provider'

await loadEnvFile(new URL('../../.env', import.meta.url))
await loadEnvFile(new URL('../.env', import.meta.url))

const { loadTestEnvFiles } = await import('../src/common/tests/load-test-env')
await loadTestEnvFiles(['.env', '.env.local', '.env.development'])

const { DB, closeDatabase } = await import('@/common/database')
const {
  AiAgentCheckbacks,
  AiAgentConversations,
  AiAgentLlmTurns,
  AiAgentMessages,
  ComputerAgentWorkerBindings,
  ComputerAgentWorkerPins,
  ComputerWorkers,
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  ExternalGatewayOutbox,
  ExternalRooms,
  LlmProviders,
  Principals,
  ScheduledTaskRuns,
  ScheduledTasks
} = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const {
  getEffectiveSkillContent,
  getSoul,
  setAgentSkillEnabled,
  setMission,
  skillsForSystemPrompt,
  syncBuiltinLibraryFromAppDirectory
} = await import('@/ai-agent/library/service')
const { resolveAiAgentRuntimeProfile } = await import('@/ai-agent/config')
const { createLlmProvider } = await import('@/llm-providers/service')
const { AiAgentRuntime } = await import('@/ai-agent/runtime')
const { AiAgentClarifyRegistry } = await import('@/ai-agent/clarify-registry')
const { ExternalGatewayRuntime } = await import('@/external-gateway/runtime')
const { registerExternalGatewayAdapterFactory } = await import('@/external-gateway/adapter-registry')
const { fullMockImCapabilities, MockImPlatform: MockImPlatformCtor } =
  await import('@/external-gateway/testing/mock-im-adapter')
const { createWebSearchTool } = await import('@/ai-agent/tools/web-search-tool')
const { createWebExtractTool } = await import('@/ai-agent/tools/web-extract-tool')
const { webProviderRegistry } = await import('@/ai-agent/web/registry')
const { WebExtractProviderConfig, WebSearchProviderConfig } = await import('@/ai-agent/web/config')
const { appConfigService } = await import('@/config/app-configure')
const { resolveComputerWorker } = await import('@/computer/service')
const { SchedulerRuntime } = await import('@/scheduler/runtime')
const { schedulerStore } = await import('@/scheduler/store')
const { externalGatewayOutbox } = await import('@/external-gateway/outbox')
const { externalGatewayProjectionSink } = await import('@/external-gateway/core/projection')

const MODEL_ID = 'minimax/minimax-m3'
const OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1'
const AMBIENT_REDIS_KEY = 'bullx-agent:ai-agent:ambient-wake'

const apiKey = Bun.env.OPENROUTER_API_KEY?.trim()
assert.ok(apiKey, 'OPENROUTER_API_KEY is required in .env, .env.local, .env.development, or the process env')

const workerId = Bun.env.BULLX_COMPUTER_E2E_WORKER_ID ?? 'dev'
const workerBaseUrl = (
  Bun.env.BULLX_COMPUTER_E2E_WORKER_URL ?? `https://localhost:${Bun.env.BULLX_COMPUTER_PORT ?? '8787'}`
).replace(/\/$/, '')

const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`.toLowerCase()
const agentUid = `llm_e2e_${suffix}`
const adapterName = `mock_llm_e2e_${suffix}`
const factoryId = `llm_e2e_factory_${suffix}`
const llmProviderId = `llme2e_${suffix}`
const webProviderId = `llm_e2e_web_${suffix}`

const roomIds = new Set<string>()
const webCalls: Array<{ args: WebSearchArgs | WebExtractArgs; kind: 'extract' | 'search' }> = []
const onlyScenarios = new Set(compact((Bun.env.LLM_E2E_ONLY ?? '').split(',').map(value => value.trim())))
const dumpTrajectory = Bun.env.LLM_E2E_DUMP_TRAJECTORY === '1'
let runtime: InstanceType<typeof ExternalGatewayRuntime> | undefined
let aiRuntime: InstanceType<typeof AiAgentRuntime> | undefined
let scheduler: InstanceType<typeof SchedulerRuntime> | undefined
let previousSearchProvider: string | undefined
let previousExtractProvider: string | undefined
let appConfigSnapshotLoaded = false

try {
  await requireDevWorker()
  const setup = await startRuntime()

  await step('core', 'user edits a live group-thread handoff and recalled context is ignored', () =>
    scenarioMultiTurnRecall(setup)
  )
  await step('compression', 'operator asks the coworker to preserve a long handoff with the light model', () =>
    scenarioCompression(setup)
  )
  await step('reset', 'operator starts a fresh customer task without previous-context leakage', () =>
    scenarioResetSession(setup)
  )
  await step('ambient', 'room explicitly asks the coworker to step in without a direct mention', () =>
    scenarioAmbient(setup)
  )
  await step('library', 'operator discovers, reads, customizes, disables, and restores a working SOP skill', () =>
    scenarioSoulAndSkills(setup)
  )
  await step('tools', 'coworker researches an external customer question and tracks follow-up work', () =>
    scenarioWebAndTodoTools(setup)
  )
  await step('clarify', 'coworker blocks on a missing business decision and resumes after the user answers', () =>
    scenarioClarify(setup)
  )
  await step('checkback', 'coworker schedules a one-shot customer follow-up and wakes itself later', () =>
    scenarioCheckBackLater(setup)
  )
  await step('computer', 'coworker updates its workspace and personal SOP through the computer', () =>
    scenarioComputerCommand(setup)
  )
  await step('runtime-skills', 'coworker verifies bundled hamelnb runtime skill through the computer', () =>
    scenarioRuntimeSkillSmokes(setup)
  )
  await step('browser', 'coworker opens a rendered public web page through the computer browser', () =>
    scenarioBrowserTool(setup)
  )
  await step('cron', 'scheduled headless work triggers a programmatic coworker turn', () =>
    scenarioCronScheduledTask(setup)
  )

  // oxlint-disable-next-line no-console
  console.log(`OK llm e2e passed: agent=${agentUid} provider=${llmProviderId} model=openrouter/${MODEL_ID}`)
} finally {
  await scheduler?.stop().catch(() => undefined)
  await runtime?.stop().catch(() => undefined)
  aiRuntime?.stop()
  if (dumpTrajectory) await dumpTrajectoryArtifact().catch(error => console.error(error))
  await cleanup()
  await closeDatabase({ timeout: 5 }).catch(() => undefined)
}

async function startRuntime() {
  previousSearchProvider = await appConfigService.get(WebSearchProviderConfig)
  previousExtractProvider = await appConfigService.get(WebExtractProviderConfig)
  appConfigSnapshotLoaded = true

  await appConfigService.set(WebSearchProviderConfig, webProviderId)
  await appConfigService.set(WebExtractProviderConfig, webProviderId)
  webProviderRegistry.register(testWebProvider())
  await syncBuiltinLibraryFromAppDirectory({ force: true })

  await createLlmProvider({
    providerId: llmProviderId,
    piProvider: 'openrouter',
    baseUrl: OPENROUTER_BASE_URL,
    apiKey,
    providerOptions: {
      headers: {
        'HTTP-Referer': 'https://agentbull.local/llm-e2e',
        'X-OpenRouter-Title': 'BullX Agent LLM E2E'
      },
      maxRetries: 1,
      timeoutMs: 180_000
    }
  })

  const platform: MockImPlatformInstance = new MockImPlatformCtor()
  registerExternalGatewayAdapterFactory({
    id: factoryId,
    create: context =>
      platform.createAdapter(context.channel.name, {
        capabilities: fullMockImCapabilities,
        groupMessageMode: 'observe_all'
      })
  })

  const models = modelConfig()
  const agent = await createAgent({
    uid: agentUid,
    metadata: {
      ai_agent: { models },
      external: {
        adapters: [{ adapter: factoryId, group_message_mode: 'may_intervene', name: adapterName }]
      }
    }
  })
  await setMission(agentUid, '')
  const profile = await resolveAiAgentRuntimeProfile({
    models,
    policy: {
      ambient: { batchWindowMs: 50, freshnessMs: 5_000 },
      compression: {
        enabled: true,
        keepRecentTokens: 1,
        maxOverflowRetries: 1,
        microcompactEnabled: false,
        microcompactKeepRecent: 6,
        reserveTokens: 0
      },
      dailyReset: { enabled: true, hour: '00:00', retryMinutes: 30 },
      generation: { maxTurns: 8 }
    }
  })

  const clarifyRegistry = new AiAgentClarifyRegistry()
  aiRuntime = new AiAgentRuntime({
    clarify: clarifyRegistry,
    clarifyHeartbeatMs: 500,
    clarifyTimeoutMs: 120_000,
    loadProfile: async () => profile
  })
  aiRuntime.setClarifyEnabled(true)
  aiRuntime.setTools([createWebSearchTool(), createWebExtractTool()], ['web_search', 'web_extract'])
  aiRuntime.setComputerEnabled(true, { resolveWorker: uid => resolveComputerWorker(uid) })

  runtime = new ExternalGatewayRuntime()
  await runtime.start({
    agentExecutor: aiRuntime,
    getChannelConfig: async () => ({ group_message_mode: 'observe_all' }),
    loadActiveAgents: async () => [agent]
  })

  const adapter = platform.adapters.get(adapterName)
  assert.ok(adapter, `mock adapter not registered: ${adapterName}`)

  return {
    adapter,
    adapterName,
    agent,
    agentUid,
    aiRuntime,
    conversationOptions(overrides: Partial<MockImConversationOptions> = {}): MockImConversationOptions {
      const channelId = overrides.channelId ?? `${adapterName}:room`
      roomIds.add(channelId)
      return {
        adapterName,
        agentUid,
        channelId,
        channelName: adapterName,
        deliver: runtime!.handleWebhook.bind(runtime),
        mode: overrides.mode ?? 'observe_all',
        threadId: overrides.threadId ?? `${channelId}:thread`,
        ...overrides
      }
    },
    platform,
    profile
  }
}

type RuntimeSetup = Awaited<ReturnType<typeof startRuntime>>

async function scenarioMultiTurnRecall(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:core`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))

  const beforeFirst = setup.platform.outbound.length
  await group.say({
    id: 'core-1',
    isMention: true,
    text: '@Agent 我们正在推进客户 Apollo 的上线交接。请像同事一样确认你已接手当前上下文，不要调用工具，简短回复。'
  })
  await waitForOutboundAfter(setup, beforeFirst)

  const beforeSecond = setup.platform.outbound.length
  await group.say({
    id: 'core-2',
    isMention: true,
    text: '@Agent 补充一条交接信息：Apollo 上线包的内部代号是 ORCHID-42。请只确认已记录，不要调用工具。'
  })
  await waitForOutboundAfter(setup, beforeSecond)

  const conversation = await conversationForRoom(roomId)
  const turns = await llmTurnsFor(conversation.id)
  assert.equal(turns.filter(row => row.kind === 'generation').length, 2)
  assert.ok(turns.every(row => row.status === 'succeeded'))

  await group.recall('core-2')
  await eventually(async () => {
    const rows = await messagesFor(conversation.id)
    assert.equal(transcriptEffect(rows.find(row => providerMessageIds(row).includes('core-2'))), 'recalled')
    assert.ok(rows.some(row => row.role === 'assistant' && transcriptEffect(row) === 'recalled'))
    assert.ok(setup.platform.outbound.some(event => event.op === 'delete'))
  }, 20_000)
}

async function scenarioCompression(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:compress`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))

  await group.say({
    id: 'compress-1',
    isMention: true,
    text: '@Agent 客服交接场景：请确认你正在跟进 Apollo 排障记录，不要调用工具。为了让后续交接摘要有可验收锚点，reply exactly: LLM_E2E_COMPRESS_ONE'
  })
  await waitForOutboundText(setup, 'LLM_E2E_COMPRESS_ONE')
  await group.say({
    id: 'compress-2',
    isMention: true,
    text: '@Agent 继续同一个排障交接：请确认你记得这是 Apollo 客户，不要调用工具。reply exactly: LLM_E2E_COMPRESS_TWO'
  })
  await waitForOutboundText(setup, 'LLM_E2E_COMPRESS_TWO')

  await group.say({ id: 'compress-command', isMention: true, text: '/compress' })
  await eventually(() => {
    assert.ok(setup.platform.outbound.some(event => event.text === 'Conversation compressed.'))
  }, 120_000)

  const conversation = await conversationForRoom(roomId)
  const summaries = (await messagesFor(conversation.id)).filter(row => row.kind === 'summary')
  assert.equal(summaries.length, 1)
  const turns = await llmTurnsFor(conversation.id)
  assert.ok(turns.some(row => row.kind === 'compression' && row.profile === 'light' && row.status === 'succeeded'))
}

async function scenarioResetSession(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:reset`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))

  const beforeFirst = setup.platform.outbound.length
  await group.say({
    id: 'reset-1',
    isMention: true,
    text: '@Agent 现在还在 Apollo 上线交接里。请确认你知道当前任务，不要调用工具，简短回复。'
  })
  await waitForOutboundAfter(setup, beforeFirst)
  const firstConversation = await conversationForRoom(roomId)
  assert.ok(
    (await llmTurnsFor(firstConversation.id)).some(row => row.kind === 'generation' && row.status === 'succeeded')
  )

  await group.say({ id: 'reset-new', isMention: true, text: '/new' })
  await waitForOutboundText(setup, 'New conversation')

  const beforeSecond = setup.platform.outbound.length
  await group.say({
    id: 'reset-2',
    isMention: true,
    text: '@Agent 新会话创建之后我们开始一个全新的客户任务：Beta 续费跟进。请确认你从新上下文开始，不要调用工具，简短回复。'
  })
  await waitForOutboundAfter(setup, beforeSecond)

  const conversations = (await conversationsFor(agentUid)).filter(row => row.conversationKey.includes(`room:${roomId}`))
  assert.equal(conversations.length, 2)
  assert.equal(conversations.filter(row => row.endedAt).length, 1)
  assert.equal(new Set(conversations.map(row => row.conversationKey)).size, 1)
}

async function scenarioAmbient(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:ambient`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId, mode: 'may_intervene' }))

  const previousOutbound = setup.platform.outbound.length
  await group.say({
    authorId: 'ambient-user',
    id: 'ambient-1',
    isMention: false,
    text: [
      '@Agent please help me now.',
      'This is an explicit request for the AI coworker to intervene and answer in the room.',
      'No other human is handling it.'
    ].join(' ')
  })

  let conversation: Awaited<ReturnType<typeof conversationForRoom>> | undefined
  await eventually(async () => {
    conversation = await conversationForRoom(roomId)
    const turns = await llmTurnsFor(conversation.id)
    const ambientTurn = turns.find(row => row.kind === 'ambient_recognizer' && row.profile === 'light')
    assert.equal(
      ambientTurn?.status,
      'succeeded',
      `ambient recognizer failed: ${JSON.stringify(ambientTurn?.response)}`
    )
    const parsed =
      isPlainObject(ambientTurn.response) && isPlainObject(ambientTurn.response.parsed)
        ? ambientTurn.response.parsed
        : undefined
    assert.equal(typeof parsed?.intervene, 'boolean')
  }, 120_000)
  assert.ok(conversation)
  const turns = await llmTurnsFor(conversation.id)
  const ambientTurn = turns.find(row => row.kind === 'ambient_recognizer' && row.profile === 'light')
  const parsed =
    isPlainObject(ambientTurn?.response) && isPlainObject(ambientTurn.response.parsed)
      ? ambientTurn.response.parsed
      : undefined
  const rows = await messagesFor(conversation.id)
  assert.ok(rows.some(row => row.role === 'im_ambient' && row.kind === 'normal'))
  if (parsed?.intervene === true) {
    await eventually(async () => {
      const updatedTurns = await llmTurnsFor(conversation.id)
      const updatedRows = await messagesFor(conversation.id)
      const recent = setup.platform.outbound
        .slice(-8)
        .map(event => `${event.op}:${event.text ?? ''}`)
        .join('\n')
      assert.ok(
        updatedTurns.some(row => row.kind === 'generation' && row.profile === 'primary' && isFinalSucceededTurn(row)),
        `ambient intervention generation did not succeed: ${JSON.stringify(updatedTurns.map(row => ({ kind: row.kind, status: row.status, response: row.response })))}`
      )
      assert.ok(updatedRows.some(row => row.role === 'im_ambient' && row.kind === 'introspection'))
      assert.ok(
        setup.platform.outbound.length > previousOutbound,
        `expected ambient outbound; recent outbound:\n${recent}`
      )
    }, 180_000)
  }
}

async function scenarioSoulAndSkills(setup: RuntimeSetup): Promise<void> {
  const soul = await getSoul(agentUid)
  assert.ok(soul?.includes('Bayesian'), 'new agent should have SOUL.md seeded from the app template')

  const initialSkills = await skillsForSystemPrompt(agentUid)
  assert.ok(
    initialSkills.some(skill => skill.name === 'jupyter-live-kernel'),
    'jupyter-live-kernel skill should be default-enabled and present in the available_skills index'
  )

  const roomId = `${adapterName}:library`
  const threadId = `${roomId}:thread`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId, threadId }))

  await sayAndWaitForLibraryStep(
    setup,
    group,
    roomId,
    threadId,
    'library-index-use-append',
    [
      '@Agent 我正在给你配置 Jupyter live-kernel SOP。不要凭印象回答，先根据 available_skills 索引读取可用技能。',
      'Call skill_view with name "jupyter-live-kernel".',
      'Then add one agent-specific operating note by calling skill_append with name "jupyter-live-kernel" and content "LLM_E2E_AGENT_APPEND_SENTINEL".',
      'After those tool results, tell me the Jupyter SOP overlay is installed and reply exactly: LLM_E2E_SKILLS_APPEND_DONE'
    ].join('\n'),
    'LLM_E2E_SKILLS_APPEND_DONE'
  )

  const conversation = await conversationForRoom(roomId)
  const names = await toolNamesForConversation(conversation.id)
  assert.ok(names.includes('skill_view'), `missing skill_view tool result: ${names.join(', ')}`)
  assert.ok(names.includes('skill_append'), `missing skill_append tool result: ${names.join(', ')}`)

  let effectiveSkill = await getEffectiveSkillContent({ agentUid, skillName: 'jupyter-live-kernel' })
  assert.ok(effectiveSkill?.content.includes('hamelnb'), 'effective skill should include canonical Jupyter SKILL.md')
  assert.ok(
    effectiveSkill?.content.includes('LLM_E2E_AGENT_APPEND_SENTINEL'),
    'effective skill should include agent AGENT_APPEND.md'
  )

  await setAgentSkillEnabled({
    agentUid,
    skillName: 'jupyter-live-kernel',
    enabled: false,
    reason: 'llm e2e disable check'
  })
  const disabledSkills = await skillsForSystemPrompt(agentUid)
  assert.ok(
    !disabledSkills.some(skill => skill.name === 'jupyter-live-kernel'),
    'console/service disabling should remove the skill from this agent available_skills index'
  )

  await setAgentSkillEnabled({
    agentUid,
    skillName: 'jupyter-live-kernel',
    enabled: true,
    reason: 'llm e2e restore check'
  })
  const restoredSkills = await skillsForSystemPrompt(agentUid)
  assert.ok(
    restoredSkills.some(skill => skill.name === 'jupyter-live-kernel'),
    'skill should return to this agent available_skills index after restore'
  )

  effectiveSkill = await getEffectiveSkillContent({ agentUid, skillName: 'jupyter-live-kernel' })
  assert.ok(
    effectiveSkill?.content.includes('LLM_E2E_AGENT_APPEND_SENTINEL'),
    'agent append should survive disable/restore'
  )
}

async function sayAndWaitForLibraryStep(
  setup: RuntimeSetup,
  group: ReturnType<MockImPlatformInstance['group']>,
  roomId: string,
  threadId: string,
  id: string,
  text: string,
  expected: string
): Promise<void> {
  const outboundStart = setup.platform.outbound.length
  await group.say({ id, isMention: true, text })
  try {
    await waitForOutboundTextInThread(setup, threadId, expected, 120_000)
  } catch (error) {
    await printScenarioDebug(setup, roomId, threadId, outboundStart, error)
    throw error
  }
}

async function scenarioWebAndTodoTools(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:tools`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))

  await group.say({
    id: 'tools-1',
    isMention: true,
    text: [
      '@Agent 客户问一个外部资料问题，还需要你留下可跟进的工作清单。请先完成资料收集和任务记录，再回答：',
      '1. web_search with query "bullx llm e2e sentinel" and limit 2.',
      '2. web_extract with urls ["https://example.test/bullx-llm-e2e"].',
      '3. todo with two items: id "search" pending content "Verify search"; id "extract" completed content "Verify extract".',
      'After the tool results, give the customer-facing status and reply exactly: LLM_E2E_TOOLS_DONE'
    ].join('\n')
  })
  await waitForOutboundText(setup, 'LLM_E2E_TOOLS_DONE', 120_000)

  assert.ok(webCalls.some(call => call.kind === 'search'))
  assert.ok(webCalls.some(call => call.kind === 'extract'))
  const conversation = await conversationForRoom(roomId)
  const names = await toolNamesForConversation(conversation.id)
  assert.ok(names.includes('web_search'), `missing web_search tool result: ${names.join(', ')}`)
  assert.ok(names.includes('web_extract'), `missing web_extract tool result: ${names.join(', ')}`)
  assert.ok(names.includes('todo'), `missing todo tool result: ${names.join(', ')}`)
}

async function scenarioClarify(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:clarify`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))

  await group.say({
    id: 'clarify-1',
    isMention: true,
    text: [
      '@Agent 我们要替客户选择发布方案，但缺少业务决策。你不能猜，请使用 clarify tool 向我确认。',
      'Use question "Choose the e2e option?" and choices ["alpha", "beta"].',
      'After I answer, continue the work and reply exactly: LLM_E2E_CLARIFY_DONE'
    ].join(' ')
  })

  await eventually(() => {
    assert.ok(setup.platform.outbound.some(event => event.text?.includes('Choose the e2e option?')))
  }, 120_000)
  await group.say({ id: 'clarify-answer', isMention: false, text: 'alpha' })
  await waitForOutboundText(setup, 'LLM_E2E_CLARIFY_DONE', 120_000)

  const conversation = await conversationForRoom(roomId)
  const names = await toolNamesForConversation(conversation.id)
  assert.ok(names.includes('clarify'), `missing clarify tool result: ${names.join(', ')}`)
}

async function scenarioCheckBackLater(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:checkback`
  const threadId = `${roomId}:thread`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId, threadId }))
  const at = new Date(Date.now() - 1_000).toISOString()

  await group.say({
    id: 'checkback-1',
    isMention: true,
    text: [
      '@Agent 客户要求你稍后自己回来确认状态，不要把这件事忘掉。You must call check_back_later exactly once.',
      `Use at "${at}", reason "e2e delayed check", check "Reply exactly LLM_E2E_CHECKBACK_WAKE",`,
      'and context_summary "llm e2e checkback context".',
      'After scheduling, tell the room the follow-up is scheduled and reply exactly: LLM_E2E_CHECKBACK_SCHEDULED'
    ].join(' ')
  })
  await waitForOutboundText(setup, 'LLM_E2E_CHECKBACK_SCHEDULED', 120_000)

  const [pending] = await DB.select()
    .from(AiAgentCheckbacks)
    .where(eq(AiAgentCheckbacks.agentUid, agentUid))
    .orderBy(sql`${AiAgentCheckbacks.createdAt} desc`)
    .limit(1)
  assert.equal(pending?.status, 'pending')
  assert.equal(pending?.source.provider_room_id, roomId)

  scheduler = new SchedulerRuntime()
  scheduler.setAgentExecutor(setup.aiRuntime)
  await scheduler.start()
  await eventually(async () => {
    const [row] = await DB.select().from(AiAgentCheckbacks).where(eq(AiAgentCheckbacks.id, pending!.id)).limit(1)
    assert.equal(row?.status, 'succeeded')
    assert.ok(row?.conversationId)
  }, 120_000)
  await scheduler.stop()
  scheduler = undefined

  await dispatchPending(setup)
  await waitForOutboundText(setup, 'LLM_E2E_CHECKBACK_WAKE', 120_000)
  const [completed] = await DB.select().from(AiAgentCheckbacks).where(eq(AiAgentCheckbacks.id, pending!.id)).limit(1)
  const turns = await llmTurnsFor(completed!.conversationId!)
  assert.ok(turns.some(row => row.kind === 'checkback_generation'))
}

async function scenarioComputerCommand(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:computer`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))
  let conversation: Awaited<ReturnType<typeof conversationForRoom>> | undefined
  let lastDiagnostic = 'computer command was not attempted'
  const text = [
    '@Agent 你需要像数字员工一样更新自己的工作区文件和个人 SOP overlay。这个任务不能只靠文字确认完成。',
    'You must call the command tool with this exact command:',
    '`mkdir -p user-files library-containers/skills/jupyter-live-kernel && printf LLM_E2E_COMMAND_DONE > user-files/llm-e2e-command.txt && printf LLM_E2E_SOUL_FROM_COMPUTER > library-containers/SOUL.md && printf LLM_E2E_APPEND_FROM_COMPUTER > library-containers/skills/jupyter-live-kernel/AGENT_APPEND.md && cat user-files/llm-e2e-command.txt && cat library-containers/SOUL.md && cat library-containers/skills/jupyter-live-kernel/AGENT_APPEND.md`.',
    'Only after the command tool result shows LLM_E2E_COMMAND_DONE, LLM_E2E_SOUL_FROM_COMPUTER, and LLM_E2E_APPEND_FROM_COMPUTER, confirm the workspace and SOP overlay were updated and reply exactly: LLM_E2E_COMPUTER_DONE.',
    'If you have not called the command tool, do not reply with LLM_E2E_COMPUTER_DONE.'
  ].join(' ')

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const existing = (await conversationsFor(agentUid)).find(row => row.conversationKey.includes(`room:${roomId}`))
    const ignoreTurnIds = new Set(existing ? (await llmTurnsFor(existing.id)).map(row => row.id) : [])
    await group.say({
      id: `computer-${attempt}`,
      isMention: true,
      text
    })
    conversation = await waitForConversationForRoom(roomId)
    const result = await waitForToolResultText(conversation.id, 'LLM_E2E_COMMAND_DONE', 180_000, ignoreTurnIds)
    if (result.ok) break
    lastDiagnostic = result.diagnostic
    await waitForAllGenerationsIdle()
  }
  assert.ok(conversation, `expected conversation for room ${roomId}`)

  conversation = await conversationForRoom(roomId)
  const serializedToolResults = JSON.stringify((await llmTurnsFor(conversation.id)).flatMap(row => row.toolResults))
  assert.match(serializedToolResults, /LLM_E2E_COMMAND_DONE/, lastDiagnostic)
  assert.match(serializedToolResults, /LLM_E2E_SOUL_FROM_COMPUTER/)
  assert.match(serializedToolResults, /LLM_E2E_APPEND_FROM_COMPUTER/)
  await waitForOutboundText(setup, 'LLM_E2E_COMPUTER_DONE', 120_000)

  assert.equal(await getSoul(agentUid), 'LLM_E2E_SOUL_FROM_COMPUTER')
  const effectiveSkill = await getEffectiveSkillContent({ agentUid, skillName: 'jupyter-live-kernel' })
  assert.ok(
    effectiveSkill?.content.includes('LLM_E2E_APPEND_FROM_COMPUTER'),
    'computer-written AGENT_APPEND.md should be visible through the DB effective skill path'
  )
}

async function scenarioRuntimeSkillSmokes(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:runtime-skills`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))
  let conversation: Awaited<ReturnType<typeof conversationForRoom>> | undefined
  let lastDiagnostic = 'runtime skill smoke was not attempted'

  const text = [
    '@Agent 请通过 computer 的 command tool 端到端验证内置 Jupyter runtime skill。',
    'First call command with command `bash /workspace/library-containers/skills/jupyter-live-kernel/scripts/smoke_live_kernel.sh` and timeout 120.',
    'Only after the command tool result shows JUPYTER_LIVE_KERNEL_SMOKE_OK, reply exactly: LLM_E2E_RUNTIME_SKILLS_DONE.',
    'If the command fails, do not reply with LLM_E2E_RUNTIME_SKILLS_DONE; explain the failing command output.'
  ].join('\n')

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const existing = (await conversationsFor(agentUid)).find(row => row.conversationKey.includes(`room:${roomId}`))
    const ignoreTurnIds = new Set(existing ? (await llmTurnsFor(existing.id)).map(row => row.id) : [])
    await group.say({
      id: `runtime-skills-${attempt}`,
      isMention: true,
      text
    })
    conversation = await waitForConversationForRoom(roomId)
    const result = await waitForToolResultText(conversation.id, 'JUPYTER_LIVE_KERNEL_SMOKE_OK', 180_000, ignoreTurnIds)
    if (result.ok) break
    lastDiagnostic = result.diagnostic
    await waitForAllGenerationsIdle()
  }
  assert.ok(conversation)
  const serializedToolResults = JSON.stringify((await llmTurnsFor(conversation.id)).flatMap(row => row.toolResults))
  assert.ok(serializedToolResults.includes('JUPYTER_LIVE_KERNEL_SMOKE_OK'), lastDiagnostic)
  const names = await toolNamesForConversation(conversation.id)
  assert.ok(names.filter(name => name === 'command').length >= 1, `missing command tool results: ${names.join(', ')}`)
}

async function scenarioBrowserTool(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:browser`
  const group = setup.platform.group(setup.conversationOptions({ channelId: roomId }))

  await group.say({
    id: 'browser-1',
    isMention: true,
    text: [
      '@Agent 请通过 computer 的 browser_open tool 端到端验证真实网页访问。',
      'Do not use web_search, web_extract, command, terminal, or browser_run for this scenario.',
      'Call browser_open with url "https://www.wikipedia.org/", waitUntil "load", waitAfterMs 1000, and timeout 120.',
      'Only after the browser_open tool result has title "Wikipedia" and rendered text containing "The Free Encyclopedia", reply exactly: LLM_E2E_BROWSER_DONE.',
      'If browser_open fails or does not show those values, do not reply with LLM_E2E_BROWSER_DONE; explain the failing browser tool result.'
    ].join('\n')
  })

  await waitForOutboundText(setup, 'LLM_E2E_BROWSER_DONE', 180_000)
  const conversation = await conversationForRoom(roomId)
  const names = await toolNamesForConversation(conversation.id)
  assert.ok(names.includes('browser_open'), `missing browser_open tool result: ${names.join(', ')}`)

  const serializedToolResults = JSON.stringify((await llmTurnsFor(conversation.id)).flatMap(row => row.toolResults))
  assert.ok(serializedToolResults.includes('Wikipedia'), 'missing Wikipedia title in browser tool result')
  assert.ok(
    serializedToolResults.includes('The Free Encyclopedia'),
    'missing Wikipedia rendered text in browser tool result'
  )
  assert.ok(serializedToolResults.includes('screenshot.png'), 'missing browser screenshot artifact')
}

async function scenarioCronScheduledTask(setup: RuntimeSetup): Promise<void> {
  const roomId = `${adapterName}:cron`
  const threadId = `${roomId}:thread`
  roomIds.add(roomId)
  const task = await schedulerStore.createTask({
    agentUid,
    delivery: { binding_name: adapterName, room_id: roomId, thread_id: threadId },
    enabled: true,
    name: `llm-e2e-cron-${suffix}`,
    nextRunAt: new Date(Date.now() - 1_000),
    payload: {
      message: '定时巡检场景：这是系统计划任务触发的无头工作。不要调用工具，reply exactly: LLM_E2E_CRON_DONE'
    },
    schedule: { kind: 'cron', expression: '* * * * *' }
  })

  scheduler = new SchedulerRuntime()
  scheduler.setAgentExecutor(setup.aiRuntime)
  await scheduler.runNow(task.id)
  await scheduler.stop()
  scheduler = undefined

  const [runAfterExecute] = await DB.select()
    .from(ScheduledTaskRuns)
    .where(eq(ScheduledTaskRuns.taskId, task.id))
    .orderBy(sql`${ScheduledTaskRuns.startedAt} desc`)
    .limit(1)
  assert.equal(runAfterExecute?.status, 'succeeded')
  assert.ok(runAfterExecute?.conversationId)
  assert.ok(runAfterExecute?.trigger === 'manual')

  await dispatchPending(setup)
  await waitForOutboundText(setup, 'LLM_E2E_CRON_DONE', 120_000)
  const [run] = await DB.select().from(ScheduledTaskRuns).where(eq(ScheduledTaskRuns.taskId, task.id)).limit(1)
  const turns = await llmTurnsFor(run!.conversationId!)
  assert.ok(turns.some(row => row.kind === 'scheduled_task'))
}

function modelConfig(): AiAgentModelsConfig {
  const base = {
    model: MODEL_ID,
    providerId: llmProviderId,
    reasoning: 'off' as const,
    temperature: 0
  }
  return {
    primary: { ...base, maxTokens: 768 },
    light: { ...base, maxTokens: 512 },
    heavy: { ...base, maxTokens: 768 }
  }
}

function testWebProvider(): WebProvider {
  return {
    id: webProviderId,
    supports: ['search', 'extract'],
    available: () => true,
    async search(args) {
      webCalls.push({ args, kind: 'search' })
      return [
        {
          title: 'BullX LLM E2E Sentinel',
          url: 'https://example.test/bullx-llm-e2e',
          snippet: `Search provider ${webProviderId} saw query: ${args.query}`
        }
      ]
    },
    async extract(args) {
      webCalls.push({ args, kind: 'extract' })
      return args.urls.map(url => ({
        url,
        title: 'Extracted BullX LLM E2E Sentinel',
        text: `Extract provider ${webProviderId} returned LLM_E2E_WEB_EXTRACT_TEXT for ${url}.`
      }))
    }
  }
}

async function dispatchPending(setup: RuntimeSetup): Promise<void> {
  await externalGatewayOutbox.dispatchPendingForBinding({
    adapter: setup.adapter,
    agent: setup.agent,
    bindingName: adapterName,
    projection: externalGatewayProjectionSink,
    room: {}
  })
}

async function waitForOutboundTextInThread(
  setup: RuntimeSetup,
  threadId: string,
  text: string,
  timeoutMs = 90_000
): Promise<void> {
  await eventually(() => {
    const relevant = setup.platform.outbound.filter(event => event.threadId === threadId)
    const recent = relevant
      .slice(-8)
      .map(event => `${event.op}:${event.text ?? ''}`)
      .join('\n')
    assert.ok(
      relevant.some(event => event.text?.includes(text)),
      `expected outbound text in thread ${threadId} to include ${text}; recent thread outbound:\n${recent || '<none>'}`
    )
  }, timeoutMs)
}

async function printScenarioDebug(
  setup: RuntimeSetup,
  roomId: string,
  threadId: string,
  outboundStart: number,
  error: unknown
): Promise<void> {
  const outbound = setup.platform.outbound.slice(outboundStart)
  const roomConversations = (await conversationsFor(agentUid)).filter(row =>
    row.conversationKey.includes(`room:${roomId}`)
  )
  const debug: Record<string, unknown> = {
    error: error instanceof Error ? error.message : String(error),
    roomId,
    threadId,
    outboundSinceStep: outbound.map(event => ({ op: event.op, threadId: event.threadId, text: event.text })),
    conversations: []
  }
  const conversations: unknown[] = []
  for (const conversation of roomConversations) {
    const turns = await llmTurnsFor(conversation.id)
    conversations.push({
      id: conversation.id,
      endedAt: conversation.endedAt,
      turns: turns.map(turn => ({
        id: turn.id,
        kind: turn.kind,
        status: turn.status,
        toolNames: jsonObjects(turn.toolResults).flatMap(toolNameFromToolResult),
        response: turn.response
      }))
    })
  }
  debug.conversations = conversations
  // oxlint-disable-next-line no-console
  console.error(`LLM_E2E_DEBUG ${JSON.stringify(debug, null, 2)}`)
}

async function waitForOutboundText(setup: RuntimeSetup, text: string, timeoutMs = 90_000): Promise<void> {
  await eventually(() => {
    const recent = setup.platform.outbound
      .slice(-8)
      .map(event => `${event.op}:${event.text ?? ''}`)
      .join('\n')
    assert.ok(
      setup.platform.outbound.some(event => event.text?.includes(text)),
      `expected outbound text to include ${text}; recent outbound:\n${recent}`
    )
  }, timeoutMs)
}

async function waitForOutboundAfter(setup: RuntimeSetup, previousLength: number, timeoutMs = 90_000): Promise<void> {
  await eventually(() => {
    assert.ok(
      setup.platform.outbound.length > previousLength,
      `expected outbound event after index ${previousLength}; current=${setup.platform.outbound.length}`
    )
  }, timeoutMs)
}

async function step(key: string, name: string, fn: () => Promise<void>): Promise<void> {
  if (onlyScenarios.size > 0 && !onlyScenarios.has(key)) return
  const start = Date.now()
  // oxlint-disable-next-line no-console
  console.log(`- ${key}: ${name}`)
  await fn()
  await waitForAllGenerationsIdle()
  // oxlint-disable-next-line no-console
  console.log(`  ok ${Date.now() - start}ms`)
}

async function conversationsFor(uid: string) {
  return DB.select()
    .from(AiAgentConversations)
    .where(eq(AiAgentConversations.agentUid, uid))
    .orderBy(AiAgentConversations.createdAt, AiAgentConversations.id)
}

async function waitForAllGenerationsIdle(timeoutMs = 240_000): Promise<void> {
  await eventually(async () => {
    const active = (await conversationsFor(agentUid)).flatMap(row => {
      const leaseId = activeGenerationLease(row.generation)
      return leaseId ? [{ id: row.id, conversationKey: row.conversationKey, leaseId }] : []
    })
    assert.equal(active.length, 0, `active generation(s) still running: ${JSON.stringify(active)}`)
  }, timeoutMs)
}

async function waitForToolResultText(
  conversationId: string,
  text: string,
  timeoutMs: number,
  ignoreTurnIds: Set<string> = new Set()
): Promise<{ diagnostic: string; ok: false } | { ok: true }> {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    const turns = (await llmTurnsFor(conversationId)).filter(row => !ignoreTurnIds.has(row.id))
    const serializedToolResults = JSON.stringify(turns.flatMap(row => row.toolResults))
    if (serializedToolResults.includes(text)) return { ok: true }
    const terminal = [...turns]
      .reverse()
      .find(
        row =>
          row.kind === 'generation' &&
          row.profile === 'primary' &&
          (row.status === 'failed' || row.status === 'cancelled' || isFinalSucceededTurn(row))
      )
    if (terminal) {
      return {
        ok: false,
        diagnostic: `missing ${text}; terminal turn: ${JSON.stringify({
          id: terminal.id,
          status: terminal.status,
          response: terminal.response,
          toolResults: terminal.toolResults
        })}`
      }
    }
    await Bun.sleep(100)
  }
  return { ok: false, diagnostic: `timed out waiting for tool result text ${text}` }
}

function activeGenerationLease(generation: unknown): string | undefined {
  if (!isPlainObject(generation)) return undefined
  if (generation.cancelled_at) return undefined
  const leaseId = generation.lease_id
  return typeof leaseId === 'string' && leaseId.length > 0 ? leaseId : undefined
}

function isFinalSucceededTurn(row: typeof AiAgentLlmTurns.$inferSelect): boolean {
  if (row.status !== 'succeeded') return false
  if (!isPlainObject(row.response)) return false
  return row.response.stop_reason === 'stop'
}

async function conversationForRoom(roomId: string) {
  const rows = (await conversationsFor(agentUid)).filter(row => row.conversationKey.includes(`room:${roomId}`))
  const active = rows.find(row => !row.endedAt) ?? rows.at(-1)
  assert.ok(active, `expected conversation for room ${roomId}`)
  return active
}

async function waitForConversationForRoom(roomId: string, timeoutMs = 20_000) {
  let conversation: Awaited<ReturnType<typeof conversationForRoom>> | undefined
  await eventually(async () => {
    conversation = await conversationForRoom(roomId)
  }, timeoutMs)
  assert.ok(conversation, `expected conversation for room ${roomId}`)
  return conversation
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

async function dumpTrajectoryArtifact(): Promise<void> {
  const conversations = await conversationsFor(agentUid)
  const conversationArtifacts = []
  for (const conversation of conversations) {
    conversationArtifacts.push({
      conversation,
      messages: await messagesFor(conversation.id),
      llmTurns: await llmTurnsFor(conversation.id)
    })
  }

  const outbox = await DB.select()
    .from(ExternalGatewayOutbox)
    .where(eq(ExternalGatewayOutbox.agentUid, agentUid))
    .orderBy(ExternalGatewayOutbox.createdAt, ExternalGatewayOutbox.outboundKey)
  const agentEvents = await DB.select()
    .from(ExternalGatewayAgentEvents)
    .where(eq(ExternalGatewayAgentEvents.agentUid, agentUid))
    .orderBy(ExternalGatewayAgentEvents.createdAt, ExternalGatewayAgentEvents.providerEventId)

  const artifactUrl = new URL(`../../var/llm-e2e/${agentUid}.json`, import.meta.url)
  await mkdir(new URL('../../var/llm-e2e/', import.meta.url), { recursive: true })
  await Bun.write(
    artifactUrl,
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        agentUid,
        adapterName,
        llmProviderId,
        model: `openrouter/${MODEL_ID}`,
        onlyScenarios: [...onlyScenarios],
        roomIds: [...roomIds],
        conversations: conversationArtifacts,
        externalGateway: { agentEvents, outbox }
      },
      null,
      2
    )
  )
  // oxlint-disable-next-line no-console
  console.log(`trajectory artifact: ${artifactUrl.pathname}`)
}

async function toolNamesForConversation(conversationId: string): Promise<string[]> {
  const turns = await llmTurnsFor(conversationId)
  return turns.flatMap(row => jsonObjects(row.toolResults).flatMap(toolNameFromToolResult))
}

function transcriptEffect(row: typeof AiAgentMessages.$inferSelect | undefined): string | undefined {
  const effect = row?.metadata.transcript_effect
  if (!isPlainObject(effect)) return undefined
  return typeof effect.state === 'string' ? effect.state : undefined
}

function providerMessageIds(row: typeof AiAgentMessages.$inferSelect): string[] {
  const refs = row.metadata.provider_refs
  if (!isPlainObject(refs)) return []
  return Array.isArray(refs.message_ids) ? refs.message_ids.filter((id): id is string => typeof id === 'string') : []
}

function jsonObjects(value: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(value)) return []
  return value.filter(isPlainObject)
}

function toolNameFromToolResult(result: Record<string, unknown>): string[] {
  if (typeof result.toolName === 'string') return [result.toolName]
  if (typeof result.tool_name === 'string') return [result.tool_name]
  const details = isPlainObject(result.details) ? result.details : undefined
  const execution = details && isPlainObject(details.bullx_execution) ? details.bullx_execution : undefined
  return typeof execution?.tool_name === 'string' ? [execution.tool_name] : []
}
async function requireDevWorker(): Promise<void> {
  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    const [row] = await DB.select({ workerId: ComputerWorkers.workerId })
      .from(ComputerWorkers)
      .where(
        and(
          eq(ComputerWorkers.workerId, workerId),
          eq(ComputerWorkers.status, 'ready'),
          sql`${ComputerWorkers.lastHeartbeatAt} > now() - interval '30 seconds'`
        )
      )
      .limit(1)
    if (row) return
    await Bun.sleep(1_000)
  }
  throw new Error(
    `Computer worker ${workerId} has no fresh DB heartbeat. Start it with "bun run services:start" before running this script. Expected worker URL: ${workerBaseUrl}`
  )
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
      await Bun.sleep(100)
    }
  }
  try {
    await assertion()
  } catch (error) {
    throw lastError ?? error
  }
}

async function loadEnvFile(url: URL): Promise<void> {
  const file = Bun.file(url)
  if (!(await file.exists())) return
  for (const line of (await file.text()).split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    const separatorIndex = trimmed.indexOf('=')
    if (separatorIndex === -1) continue

    const name = trimmed.slice(0, separatorIndex).trim()
    const rawValue = trimmed.slice(separatorIndex + 1).trim()
    if (!name || Bun.env[name] !== undefined) continue

    Bun.env[name] = rawValue.replace(/^(['"])(.*)\1$/, '$2')
  }
}

async function cleanup(): Promise<void> {
  await clearAmbientRedisMembersForAgent()

  if (appConfigSnapshotLoaded) {
    if (previousSearchProvider === undefined) await appConfigService.delete(WebSearchProviderConfig)
    else await appConfigService.set(WebSearchProviderConfig, previousSearchProvider)

    if (previousExtractProvider === undefined) await appConfigService.delete(WebExtractProviderConfig)
    else await appConfigService.set(WebExtractProviderConfig, previousExtractProvider)
  }

  if (dumpTrajectory) {
    // oxlint-disable-next-line no-console
    console.log(`preserving llm e2e DB rows for trajectory dump: agent=${agentUid}`)
    return
  }

  await DB.delete(ScheduledTaskRuns).where(eq(ScheduledTaskRuns.agentUid, agentUid))
  await DB.delete(ScheduledTasks).where(eq(ScheduledTasks.agentUid, agentUid))
  await DB.delete(AiAgentCheckbacks).where(eq(AiAgentCheckbacks.agentUid, agentUid))
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
  await DB.delete(LlmProviders).where(eq(LlmProviders.providerId, llmProviderId))
}

async function clearAmbientRedisMembersForAgent(): Promise<void> {
  const members = await redis.send('ZRANGE', [AMBIENT_REDIS_KEY, '0', '-1']).catch(() => [])
  if (!Array.isArray(members)) return
  const testMembers = members.filter(member => typeof member === 'string' && member.includes(agentUid))
  if (testMembers.length > 0) await redis.send('ZREM', [AMBIENT_REDIS_KEY, ...testMembers]).catch(() => undefined)
}
