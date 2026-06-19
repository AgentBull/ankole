/**
 * User-story smoke run: the production task that wedged on 2026-06-12 —
 * "帮我根据推特上美股大神serenity选股的方法论，寻找一下a股下一个潜在的板块的机会。"
 * — replayed end-to-end against a real OpenRouter gpt-5.5 profile, the real
 * local computer worker (financial-data image), and the real skill library.
 * Web search/extract are story-shaped local fixtures so the run does not
 * depend on SERP credentials; everything else is the production code path
 * (gateway → lease → generation → watchdog/liveness → streaming → outbox).
 *
 * Usage: bun scripts/serenity-story.ts   (OPENROUTER_API_KEY in app/.env.local)
 */
import assert from 'node:assert/strict'
import type {
  MockImConversationOptions,
  MockImPlatform as MockImPlatformInstance
} from '../src/external-gateway/testing/mock-im-adapter'
import type { WebProvider } from '../src/ai-agent/web/provider'

await loadEnvFile(new URL('../../.env', import.meta.url))
await loadEnvFile(new URL('../.env', import.meta.url))
const { loadTestEnvFiles } = await import('../src/common/tests/load-test-env')
await loadTestEnvFiles(['.env', '.env.local', '.env.development'])

const { DB, closeDatabase } = await import('@/common/database')
const { AiAgentConversations, AiAgentLlmTurns, ComputerWorkers, LlmProviders, Principals } =
  await import('@/common/db-schema')
const { and, eq, sql } = await import('drizzle-orm')
const { createAgent } = await import('@/principals/agents/service')
const { setAgentSkillEnabled, setMission, syncBuiltinLibraryFromAppDirectory } =
  await import('@/ai-agent/library/service')
const { resolveAiAgentRuntimeProfile } = await import('@/ai-agent/config')
const { createLlmProvider } = await import('@/llm-providers/service')
const { AiAgentRuntime } = await import('@/ai-agent/runtime')
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

const PROMPT = '帮我根据推特上美股大神serenity选股的方法论，寻找一下a股下一个潜在的板块的机会。'
const MODEL_ID = Bun.env.SERENITY_MODEL ?? 'openai/gpt-5.5'
const LIGHT_MODEL_ID = 'minimax/minimax-m3'
const OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1'
const WALL_CLOCK_BUDGET_MS = Number(Bun.env.SERENITY_BUDGET_MS ?? 12 * 60_000)

const apiKey = Bun.env.OPENROUTER_API_KEY?.trim()
assert.ok(apiKey, 'OPENROUTER_API_KEY required')

const suffix = `${Date.now().toString(36)}`.toLowerCase()
const agentUid = `serenity_story_${suffix}`
const adapterName = `mock_serenity_${suffix}`
const factoryId = `serenity_factory_${suffix}`
const llmProviderId = `serenity_or_${suffix}`
const webProviderId = `serenity_web_${suffix}`

let previousSearchProvider: string | undefined
let previousExtractProvider: string | undefined
let runtime: InstanceType<typeof ExternalGatewayRuntime> | undefined
let aiRuntime: InstanceType<typeof AiAgentRuntime> | undefined

function log(line: string): void {
  // oxlint-disable-next-line no-console
  console.log(`\x1b[36m[story]\x1b[0m ${line}`)
}

try {
  const [worker] = await DB.select()
    .from(ComputerWorkers)
    .where(and(eq(ComputerWorkers.workerId, 'dev'), eq(ComputerWorkers.status, 'ready')))
    .limit(1)
  assert.ok(worker, 'dev computer worker must be registered and ready (docker compose)')

  previousSearchProvider = await appConfigService.get(WebSearchProviderConfig)
  previousExtractProvider = await appConfigService.get(WebExtractProviderConfig)
  await appConfigService.set(WebSearchProviderConfig, webProviderId)
  await appConfigService.set(WebExtractProviderConfig, webProviderId)
  webProviderRegistry.register(storyWebProvider())
  await syncBuiltinLibraryFromAppDirectory()

  await createLlmProvider({
    providerId: llmProviderId,
    llmProvider: 'openrouter',
    baseUrl: OPENROUTER_BASE_URL,
    apiKey,
    providerOptions: {
      headers: { 'HTTP-Referer': 'https://agentbull.local/serenity-story' },
      maxRetries: 1,
      timeoutMs: 600_000
    }
  })

  const platform: MockImPlatformInstance = new MockImPlatformCtor()
  registerExternalGatewayAdapterFactory({
    id: factoryId,
    create: context =>
      platform.createAdapter(context.channel.name, {
        capabilities: fullMockImCapabilities,
        groupMessageMode: 'may_intervene',
        enableStreaming: true
      })
  })

  const models = {
    primary: { providerId: llmProviderId, model: MODEL_ID, reasoning: 'medium' as const },
    light: { providerId: llmProviderId, model: LIGHT_MODEL_ID, reasoning: 'off' as const, maxTokens: 1200 },
    heavy: { providerId: llmProviderId, model: MODEL_ID, reasoning: 'high' as const }
  }
  const agent = await createAgent({
    uid: agentUid,
    metadata: {
      ai_agent: { models },
      external: { adapters: [{ adapter: factoryId, group_message_mode: 'may_intervene', name: adapterName }] }
    }
  })
  await setMission(agentUid, '你是二级研究员，擅长 A 股板块研究。回答用中文。')
  for (const skillName of ['financial-data', 'search-x']) {
    await setAgentSkillEnabled({ agentUid, skillName, enabled: true }).catch(error => {
      log(`skill ${skillName} not enabled: ${error}`)
    })
  }

  const profile = await resolveAiAgentRuntimeProfile({
    models,
    policy: { generation: { maxTurns: 28 } }
  })
  log(`profile: model=${MODEL_ID} stallTimeoutMs=${profile.generation.stallTimeoutMs} maxTurns=28`)

  aiRuntime = new AiAgentRuntime({ loadProfile: async () => profile })
  aiRuntime.setClarifyEnabled(true)
  aiRuntime.setTools([createWebSearchTool(), createWebExtractTool()], ['web_search', 'web_extract'])
  aiRuntime.setComputerEnabled(true, { resolveWorker: uid => resolveComputerWorker(uid) })

  runtime = new ExternalGatewayRuntime()
  await runtime.start({
    agentExecutor: aiRuntime,
    getChannelConfig: async () => ({ group_message_mode: 'may_intervene' }),
    loadActiveAgents: async () => [agent]
  })
  const adapter = platform.adapters.get(adapterName)
  assert.ok(adapter)

  const conversationOptions: MockImConversationOptions = {
    adapterName,
    agentUid,
    channelId: `${adapterName}:room`,
    channelName: adapterName,
    deliver: runtime.handleWebhook.bind(runtime),
    mode: 'may_intervene',
    threadId: `${adapterName}:room:thread`
  }
  const group = platform.group(conversationOptions)

  const startedAt = Date.now()
  log(`sending the production prompt verbatim…`)
  const delivered = await group.say({ id: 'serenity-1', isMention: true, text: `@Agent ${PROMPT}` })
  assert.ok(delivered.ok, `delivery failed: ${delivered.status} ${await delivered.text()}`)

  let printedOutbound = 0
  let printedCards = 0
  let finalAnswer: string | undefined
  while (Date.now() - startedAt < WALL_CLOCK_BUDGET_MS) {
    while (printedOutbound < platform.outbound.length) {
      const event = platform.outbound[printedOutbound++]!
      log(
        `outbound[${event.op}] ${String(event.text ?? '')
          .slice(0, 160)
          .replaceAll('\n', ' ⏎ ')}`
      )
    }
    while (printedCards < platform.streamingCards.length) {
      const card = platform.streamingCards[printedCards++]!
      log(`streaming card opened (#${printedCards})`)
      void card
    }
    const finishedCard = platform.streamingCards.find(card => card.finalStatus === 'completed' && card.finalText)
    const finalPost = platform.outbound.find(
      event => event.op === 'post' && (event.text?.length ?? 0) > 400 && !event.text?.includes('todo')
    )
    if (finishedCard?.finalText || finalPost?.text) {
      finalAnswer = finishedCard?.finalText ?? finalPost?.text ?? undefined
      break
    }
    await Bun.sleep(2_000)
  }

  const [conversation] = await DB.select()
    .from(AiAgentConversations)
    .where(eq(AiAgentConversations.agentUid, agentUid))
    .limit(1)
  const turns = conversation
    ? await DB.select({
        kind: AiAgentLlmTurns.kind,
        status: AiAgentLlmTurns.status,
        callIndex: AiAgentLlmTurns.callIndex,
        startedAt: AiAgentLlmTurns.startedAt,
        completedAt: AiAgentLlmTurns.completedAt,
        toolResults: AiAgentLlmTurns.toolResults
      })
        .from(AiAgentLlmTurns)
        .where(eq(AiAgentLlmTurns.conversationId, conversation.id))
        .orderBy(AiAgentLlmTurns.startedAt)
    : []

  log('--- RESULT ---')
  log(`elapsed: ${Math.round((Date.now() - startedAt) / 1000)}s, llm calls: ${turns.length}`)
  for (const turn of turns) {
    const duration = turn.completedAt ? `${Math.round((+turn.completedAt - +turn.startedAt) / 1000)}s` : 'OPEN'
    const tools = (turn.toolResults as unknown[]).length
    log(`  call#${turn.callIndex} ${turn.kind} ${turn.status} ${duration} tools=${tools}`)
  }
  log(`lease after run: ${JSON.stringify(conversation?.generation.lease_id ?? null)}`)
  log(
    `streaming cards: ${platform.streamingCards.length}, final card status: ${platform.streamingCards.at(-1)?.finalStatus}`
  )
  if (finalAnswer) {
    log(`FINAL ANSWER (${finalAnswer.length} chars):`)
    // oxlint-disable-next-line no-console
    console.log(finalAnswer)
  } else {
    log('NO final answer within wall-clock budget — inspect turns above for where it blocked')
  }
} finally {
  await runtime?.stop().catch(() => undefined)
  aiRuntime?.stop()
  if (previousSearchProvider) await appConfigService.set(WebSearchProviderConfig, previousSearchProvider)
  if (previousExtractProvider) await appConfigService.set(WebExtractProviderConfig, previousExtractProvider)
  await DB.delete(LlmProviders)
    .where(eq(LlmProviders.providerId, llmProviderId))
    .catch(() => undefined)
  await DB.execute(sql`select 1`).catch(() => undefined)
  await closeDatabase({ timeout: 5 }).catch(() => undefined)
  void Principals
}

function storyWebProvider(): WebProvider {
  return {
    id: webProviderId,
    supports: ['search', 'extract'],
    available: () => true,
    async search(args) {
      log(`web_search: ${args.query}`)
      const query = args.query.toLowerCase()
      if (query.includes('serenity')) {
        return [
          {
            title: 'serenity (@serenitytrades) 选股方法论梳理',
            url: 'https://example.local/serenity-methodology',
            snippet:
              'serenity 的选股框架：1) 相对强度 RS 领先的板块龙头；2) 行业景气拐点叠加成交量突破；' +
              '3) 机构资金持续流入；4) 催化剂驱动(政策/产品周期/涨价)；5) 阶段性集中持仓强势板块。'
          },
          {
            title: 'Thread: how serenity screens sector leaders',
            url: 'https://example.local/serenity-thread',
            snippet: 'Volume breakout + RS line new high + sector rotation into early-stage themes.'
          }
        ]
      }
      return [
        {
          title: 'A股板块资金流向与景气度观察',
          url: 'https://example.local/a-share-sectors',
          snippet: '近期资金关注：算力/液冷、低空经济、固态电池、创新药出海、消费电子复苏。'
        }
      ]
    },
    async extract(args) {
      log(`web_extract: ${args.urls.join(', ')}`)
      return args.urls.map(url => ({
        url,
        title: 'serenity 方法论全文(本地仿真)',
        text:
          'serenity 的核心方法论：寻找相对强度领先且基本面出现拐点的板块，确认成交量与价格同步突破，' +
          '优先选择板块内市占率提升的龙头公司，在催化剂(政策、涨价、新产品周期)明确时集中持仓。' +
          '风险控制：跌破关键均线或 RS 走弱即退出。将此框架映射到 A 股时，应结合申万行业指数的量价数据、' +
          '北向资金/两融流向以及行业景气指标(订单、价格、库存周期)。'
      }))
    }
  }
}

async function loadEnvFile(url: URL): Promise<void> {
  const file = Bun.file(url)
  if (!(await file.exists())) return
  for (const line of (await file.text()).split('\n')) {
    const match = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/.exec(line)
    if (!match) continue
    const key = match[1]!
    if (Bun.env[key] !== undefined) continue
    let value = match[2] ?? ''
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1)
    }
    Bun.env[key] = value
  }
}
