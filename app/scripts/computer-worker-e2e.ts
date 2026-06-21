import assert from 'node:assert/strict'
import { fauxAssistantMessage, fauxToolCall, registerFauxProvider, type FauxProviderRegistration } from '@/llm'
import { and, eq, sql } from 'drizzle-orm'
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
  ComputerWorkers,
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  ExternalMessages,
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
const { resolveComputerWorker } = await import('@/computer/service')

const workerId = requiredEnv(
  'BULLX_COMPUTER_E2E_WORKER_ID',
  'Set BULLX_COMPUTER_E2E_WORKER_ID to an isolated test worker id; the script no longer defaults to the dev worker because that reuses stale computer workspaces.'
)
const workerBaseUrl = (
  Bun.env.BULLX_COMPUTER_E2E_WORKER_URL ?? `https://localhost:${Bun.env.BULLX_COMPUTER_PORT ?? '8787'}`
).replace(/\/$/, '')
const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentUid = `computer_e2e_${suffix}`
const adapterName = `mock_computer_e2e_${suffix}`
const factoryId = `computer_e2e_factory_${suffix}`
const attachmentText = `computer-attachment-e2e:${agentUid}`
const roomIds = new Set<string>()
let runtime: InstanceType<typeof ExternalGatewayRuntime> | undefined
let aiRuntime: InstanceType<typeof AiAgentRuntime> | undefined
let registration: FauxProviderRegistration | undefined

/**
 * Reads a required environment value with a script-specific setup hint.
 */
function requiredEnv(name: string, message: string): string {
  const value = Bun.env[name]?.trim()
  assert.ok(value, message)
  return value
}

try {
  await requireDevWorker()

  // P1: conversation-scoped execution state on one agent session. Persistent
  // shells are independent per execution scope, and scope-suffixed tmux names
  // (what interactive_terminal generates for the same user-visible name) coexist.
  {
    const { Computer } = await import('@agentbull/bullx-computer')
    const computer = await Computer.getOrCreate({
      agentUid,
      resolveWorker: uid => resolveComputerWorker(uid)
    })
    const scopeA = `conv_a_${suffix}`
    const scopeB = `conv_b_${suffix}`
    await computer.runShellCommand('cd /tmp && export BULLX_E2E_SCOPE=a', { shellScope: scopeA })
    const shellA = await computer.runShellCommand('echo "cwd=$(pwd) scope=$BULLX_E2E_SCOPE"', { shellScope: scopeA })
    const outputA = await shellA.output('both')
    assert.match(outputA, /cwd=\/tmp scope=a/, `scope A shell must keep its own cwd/env: ${outputA}`)
    const shellB = await computer.runShellCommand('echo "cwd=$(pwd) scope=${BULLX_E2E_SCOPE:-unset}"', {
      shellScope: scopeB
    })
    const outputB = await shellB.output('both')
    assert.doesNotMatch(outputB, /cwd=\/tmp/, `scope B shell must not inherit scope A cwd: ${outputB}`)
    assert.match(outputB, /scope=unset/, `scope B shell must not inherit scope A env: ${outputB}`)

    // Scope-suffixed tmux names for the same user-visible name (>64 chars
    // included) coexist on the keeper-hosted tmux server, which outlives the
    // transient per-command sandboxes: sessions stay listable, capturable, and
    // killable across tool calls.
    const tmuxA = `main--s-a${suffix.slice(-7)}`
    const tmuxB = `main--s-b${suffix.slice(-7)}`
    const startedA = await computer.terminals.start(tmuxA, { command: 'bash' })
    const startedB = await computer.terminals.start(tmuxB, { command: 'bash' })
    assert.equal(startedA.status, 'started', `tmux ${tmuxA} must start: ${JSON.stringify(startedA)}`)
    assert.equal(startedB.status, 'started', `tmux ${tmuxB} must start: ${JSON.stringify(startedB)}`)
    const terminalNames = (await computer.terminals.list()).map(terminal => terminal.name)
    assert.ok(
      terminalNames.includes(tmuxA) && terminalNames.includes(tmuxB),
      `tmux server must keep both scoped sessions alive: ${JSON.stringify(terminalNames)}`
    )
    await computer.terminals.send(tmuxA, { input: 'echo "marker:$BULLX_AGENT_UID"', enter: true })
    await eventually(async () => {
      const capture = await computer.terminals.capture(tmuxA, { lines: 50 })
      assert.match(capture.screen, /marker:/, `tmux capture must show the echoed marker: ${capture.screen}`)
    }, 10_000)
    await computer.terminals.kill(tmuxA)
    await computer.terminals.kill(tmuxB)
    const afterKill = (await computer.terminals.list()).map(terminal => terminal.name)
    assert.ok(
      !afterKill.includes(tmuxA) && !afterKill.includes(tmuxB),
      `killed tmux sessions must disappear from the list: ${JSON.stringify(afterKill)}`
    )
    console.warn('computer-worker-e2e: conversation-scope isolation OK (shell scopes + tmux lifecycle)')
  }

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
        command: [
          "python3 - <<'PY'",
          'import pathlib',
          'import os',
          'import time',
          'roots = [',
          '    pathlib.Path("/workspace/user-files/external-gateway"),',
          '    pathlib.Path("/workspaces/user-files") / os.environ["BULLX_AGENT_UID"] / "external-gateway",',
          ']',
          'matches = []',
          'deadline = time.time() + 5',
          'while time.time() < deadline and not matches:',
          '    for root in roots:',
          '        matches.extend(sorted(root.rglob("*inbound.txt")))',
          '    if not matches:',
          '        time.sleep(0.1)',
          'if not matches:',
          '    workspace = pathlib.Path("/workspace")',
          '    print("BULLX_ATTACHMENT_DEBUG agent_uid=", os.environ.get("BULLX_AGENT_UID"))',
          '    print("BULLX_ATTACHMENT_DEBUG roots=", roots)',
          '    print("BULLX_ATTACHMENT_DEBUG workspace_exists=", workspace.exists())',
          '    for path in sorted(workspace.rglob("*"))[:80]:',
          '        print("BULLX_ATTACHMENT_DEBUG", path)',
          '    raise AssertionError("no inbound attachment under expected user-files roots")',
          'print(matches[0].read_text())',
          'PY'
        ].join('\n'),
        timeout: 10
      })
    ]),
    fauxAssistantMessage('computer attachment read finished')
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
    getComputerFileWriter: async uid => {
      const { Computer } = await import('@agentbull/bullx-computer')
      return Computer.getOrCreate({
        agentUid: uid,
        resolveWorker: resolveComputerWorker
      })
    },
    getChannelConfig: async () => ({ group_message_mode: 'observe_all' }),
    loadActiveAgents: async () => [agent]
  })

  const dm = platform.dm(conversationOptions(runtime, agentUid, adapterName))
  roomIds.add(dm.channelId)
  await dm.say({
    attachments: [
      {
        data: attachmentText,
        mimeType: 'text/plain',
        name: 'inbound.txt',
        type: 'file'
      }
    ],
    id: 'm1',
    text: '@Agent read the attached file in your computer'
  })

  const materialized = await waitForMaterializedAttachment(dm.channelId, 'm1')
  assert.equal(materialized.status, 'saved')
  assert.equal(typeof materialized.computerPath, 'string')
  assert.equal(materialized.computerPath.includes('/workspace/user-files/external-gateway/'), true)
  {
    const { Computer } = await import('@agentbull/bullx-computer')
    const computer = await Computer.getOrCreate({
      agentUid,
      resolveWorker: uid => resolveComputerWorker(uid)
    })
    const data = await computer.readFileToBuffer({ path: materialized.computerPath as string })
    assert.equal(data?.toString('utf8'), attachmentText)
  }

  await eventually(() => {
    assert.equal(
      platform.outbound.some(event => event.op === 'post' && event.text === 'computer attachment read finished'),
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
  assert.equal(serializedToolResults.includes(attachmentText), true)
  assert.equal(serializedToolResults.includes('/workspace/user-files/external-gateway'), true)

  // oxlint-disable-next-line no-console
  console.log(`OK computer worker e2e passed: agent=${agentUid} worker=${workerId} url=${workerBaseUrl}`)
} finally {
  await runtime?.stop()
  aiRuntime?.stop()
  registration?.unregister()
  await cleanup()
  await cleanupMediaFiles()
  await closeDatabase({ timeout: 5 }).catch(() => undefined)
}

/**
 * Builds the mock IM conversation shape used to enter the real gateway path.
 */
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

/**
 * Creates a deterministic runtime profile backed by the faux provider.
 */
async function runtimeProfile(currentRegistration: FauxProviderRegistration): Promise<AiAgentRuntimeProfile> {
  const primary = currentRegistration.getModel('primary')!
  const light = currentRegistration.getModel('light')!
  const heavy = currentRegistration.getModel('heavy')!
  return {
    ambient: { batchWindowMs: 20, hardCapMs: 5_000 },
    parallelism: { maxConversationsPerAgent: 16 },
    generation: { maxTurns: 100 },
    compression: {
      enabled: true,
      keepRecentTokens: 20_000,
      maxOverflowRetries: 1,
      reserveTokens: 0,
      microcompactEnabled: false,
      microcompactKeepRecent: 6
    },
    dailyReset: { enabled: true, hour: '00:00' },
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

/**
 * Waits for the target worker to publish a fresh DB heartbeat.
 */
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

/**
 * Removes temporary DB rows created by this E2E run.
 */
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

/**
 * Waits until the gateway has mirrored and materialized an inbound attachment.
 */
async function waitForMaterializedAttachment(roomId: string, messageId: string): Promise<Record<string, unknown>> {
  let row: typeof ExternalMessages.$inferSelect | undefined
  await eventually(async () => {
    ;[row] = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, messageId)))
      .limit(1)
    const materialized = materializedAttachment(row)
    assert.equal(
      materialized?.status,
      'saved',
      `expected saved materialized attachment, got ${JSON.stringify(row?.attachments)}`
    )
  }, 10_000)
  const materialized = materializedAttachment(row)
  assert.ok(materialized)
  return materialized
}

/**
 * Extracts the materialized attachment metadata from the projected message row.
 */
function materializedAttachment(
  row: typeof ExternalMessages.$inferSelect | undefined
): Record<string, unknown> | undefined {
  const attachment = row?.attachments[0]
  if (typeof attachment !== 'object' || attachment === null || Array.isArray(attachment)) return undefined
  const materialized = attachment.materialized
  if (typeof materialized !== 'object' || materialized === null || Array.isArray(materialized)) return undefined
  return materialized
}

/**
 * Deletes user-file artifacts written into the temporary computer workspace.
 */
async function cleanupMediaFiles(): Promise<void> {
  const { Computer } = await import('@agentbull/bullx-computer')
  const computer = await Computer.getOrCreate({
    agentUid,
    resolveWorker: uid => resolveComputerWorker(uid)
  })
  await computer
    .runCommand('rm', ['-rf', '/workspace/user-files/external-gateway'], { timeoutMs: 5_000 })
    .catch(() => undefined)
}

/**
 * Retries an assertion while async gateway/worker side effects settle.
 */
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
