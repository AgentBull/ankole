import { afterEach, describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { runCodexJobSession } from '../src/core/codex-runner/job/session'
import type { PreparedCodexJobExecution } from '../src/core/codex-runner/job/setup'
import { prepareAgentPlugins } from '../src/core/codex-runner/runtime/agent-plugin-materializer'
import type { CodexJobOptions } from '../src/core/turns/turn_options'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import {
  BackgroundAgentJobResponseSchema,
  BackgroundAgentJobTurnItemsListResponseSchema,
  BackgroundAgentJobTurnUpsertResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { TurnStart } from '../src/lanes/actor_lane'
import {
  rpcMethods,
  type BackgroundAgentJobResponse,
  type RPCRequester,
  type RPCRequestInit
} from '../src/lanes/rpc_lane'

/**
 * These tests drive the recovery ladder through a handoff built from the
 * declared `PreparedCodexJobExecution` type. Only the app-server transport is
 * real: a scripted fake process answers the JSON-RPC methods the session uses
 * and writes every request it receives to a log file.
 */

type FakeTurn = { status: 'completed'; text: string } | { status: 'failed'; error: Record<string, unknown> }

type FakeScenario = {
  /** One entry for each accepted `turn/start`, in order. */
  turns: FakeTurn[]
  /** How the explicit compaction turn ends after its `contextCompaction` item. */
  compaction?: { completeDelayMs: number; status: 'completed' | 'failed' }
}
type LogEntry = Record<string, unknown> & { received?: string; emitted?: string; rejected?: string }

type RecordedStatusUpdate = RPCRequestInit<'background_agent_job.status.update'> & {
  metadataJson?: Uint8Array
  resultJson?: Uint8Array
}
type RecordedTurnUpsert = RPCRequestInit<'background_agent_job.turn.upsert'>

type StoredTurnItem = { position: number; itemKey: string; item: Record<string, unknown> }

const jobID = '1000'
const continuationInput =
  'Continue the Job task after the transient runtime error. Inspect the current workspace before repeating any side effect, then re-check the original acceptance criteria.'
const previousFlockBinary = process.env.ANKOLE_FLOCK_BINARY
const roots: string[] = []

afterEach(() => {
  if (previousFlockBinary === undefined) delete process.env.ANKOLE_FLOCK_BINARY
  else process.env.ANKOLE_FLOCK_BINARY = previousFlockBinary
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('@ankole/agent-computer Codex Job session recovery ladder', () => {
  it('retries a transient turn failure on the same thread with the continuation input', async () => {
    const fixture = sessionFixture('agent-c3-retry', {
      turns: [
        { status: 'failed', error: { message: 'server overloaded', codexErrorInfo: 'serverOverloaded' } },
        { status: 'completed', text: 'done after retry' }
      ]
    })

    const result = await runCodexJobSession(turnStart(), fixture.opts, jobID, fixture.job, fixture.prepared)

    expect(result).toEqual({ kind: 'noop_completed', reason: 'background_agent_job_committed' })
    expect(fixture.statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
    expect(parsedJSON(fixture.statusUpdates.at(-1)?.resultJson)).toMatchObject({
      output_text: 'done after retry',
      runtime_thread_id: 'thread-1'
    })
    const turnStarts = fixture.log().filter(entry => entry.received === 'turn/start')
    expect(turnStarts.map(entry => [entry.threadId, entry.input])).toEqual([
      ['thread-1', fixture.job.task],
      ['thread-1', continuationInput]
    ])
    expect(latestTurnStatuses(fixture.turnUpserts)).toEqual([
      ['turn-1', 'agent', 'failed'],
      ['turn-2', 'agent', 'completed']
    ])
    expect(fixture.cleanupCalls()).toBe(1)
  })

  it('starts the retry turn only after the explicit compaction turn completes', async () => {
    const fixture = sessionFixture('agent-c3-compact', {
      turns: [
        { status: 'failed', error: { message: 'context window exceeded', codexErrorInfo: 'contextWindowExceeded' } },
        { status: 'completed', text: 'done after compaction' }
      ],
      compaction: { completeDelayMs: 150, status: 'completed' }
    })
    const controller = new AbortController()
    fixture.opts.abortSignal = controller.signal

    const run = runCodexJobSession(turnStart(), fixture.opts, jobID, fixture.job, fixture.prepared)
    // Production Job 1503: the input submitted while the compaction turn was
    // still active was rejected with ActiveTurnNotSteerable { Compact }.
    const rejection = await raceWithLog(run, fixture, entry => entry.rejected !== undefined)
    if (rejection) controller.abort(new Error('turn/start was submitted while the compaction turn was active'))
    const result = await run

    expect(rejection).toBeUndefined()
    expect(result).toEqual({ kind: 'noop_completed', reason: 'background_agent_job_committed' })
    expect(fixture.statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
    expect(parsedJSON(fixture.statusUpdates.at(-1)?.resultJson)).toMatchObject({ output_text: 'done after compaction' })
    expect(
      fixture
        .log()
        .map(entry => entry.received ?? entry.emitted)
        .filter(event => event !== 'initialize' && event !== 'initialized' && event !== 'config/batchWrite')
        .slice(0, 5)
    ).toEqual(['thread/start', 'turn/start', 'thread/compact/start', 'compaction_turn_completed', 'turn/start'])
    expect(latestTurnStatuses(fixture.turnUpserts)).toEqual([
      ['turn-1', 'agent', 'failed'],
      ['turn-compact-1', 'compaction', 'completed'],
      ['turn-2', 'agent', 'completed']
    ])
  }, 20_000)

  it('fails the attempt when the compaction turn itself fails', async () => {
    const fixture = sessionFixture('agent-c3-compact-failed', {
      turns: [
        { status: 'failed', error: { message: 'context window exceeded', codexErrorInfo: 'contextWindowExceeded' } }
      ],
      compaction: { completeDelayMs: 10, status: 'failed' }
    })
    const controller = new AbortController()
    fixture.opts.abortSignal = controller.signal

    const run = runCodexJobSession(turnStart(), fixture.opts, jobID, fixture.job, fixture.prepared)
    const rejection = await raceWithLog(run, fixture, entry => entry.rejected !== undefined)
    if (rejection) controller.abort(new Error('turn/start was submitted while the compaction turn was active'))

    expect(rejection).toBeUndefined()
    await expect(run).rejects.toThrow('compaction failed upstream')
    expect(fixture.statusUpdates.map(update => update.status)).toEqual(['running'])
    expect(fixture.log().filter(entry => entry.received === 'turn/start')).toHaveLength(1)
    expect(latestTurnStatuses(fixture.turnUpserts)).toEqual([
      ['turn-1', 'agent', 'failed'],
      ['turn-compact-1', 'compaction', 'failed']
    ])
    expect(fixture.cleanupCalls()).toBe(1)
  }, 20_000)

  it('rebuilds a thread lost mid-run from the durable workspace and records the new anchor', async () => {
    const fixture = sessionFixture('agent-c3-replace', {
      turns: [
        { status: 'failed', error: { message: 'No rollout found for thread' } },
        { status: 'completed', text: 'done on the replacement thread' }
      ]
    })

    const result = await runCodexJobSession(turnStart(), fixture.opts, jobID, fixture.job, fixture.prepared)

    expect(result).toEqual({ kind: 'noop_completed', reason: 'background_agent_job_committed' })
    expect(fixture.statusUpdates.map(update => [update.status, update.runtimeThreadId])).toEqual([
      ['running', 'thread-1'],
      ['running', 'thread-2'],
      ['succeeded', 'thread-2']
    ])
    expect(parsedJSON(fixture.statusUpdates[1]?.metadataJson)).toEqual({
      runtime_thread_recreated_reason: 'new_thread_from_bounded_history'
    })
    expect(fixture.log().some(entry => entry.received === 'thread/inject_items')).toBe(false)
    const secondTurn = fixture.log().filter(entry => entry.received === 'turn/start')[1]
    expect(secondTurn?.threadId).toBe('thread-2')
    expect(String(secondTurn?.input)).toContain(fixture.job.task)
    expect(String(secondTurn?.input)).toContain('The previous Codex thread could not be resumed')
    expect(String(secondTurn?.input)).toContain(continuationInput)
  })

  it('replays the stored transcript into the replacement thread when the store has items', async () => {
    const fixture = sessionFixture(
      'agent-c3-replay',
      {
        turns: [
          { status: 'failed', error: { message: 'No rollout found for thread' } },
          { status: 'completed', text: 'done after replay' }
        ]
      },
      [
        {
          position: 0,
          itemKey: 'client:event-0',
          item: { type: 'userMessage', id: 'user-0', content: [{ type: 'text', text: 'earlier task text' }] }
        },
        { position: 1, itemKey: 'message-0', item: { type: 'agentMessage', id: 'message-0', text: 'earlier reply' } }
      ]
    )

    await runCodexJobSession(turnStart(), fixture.opts, jobID, fixture.job, fixture.prepared)

    expect(parsedJSON(fixture.statusUpdates[1]?.metadataJson)).toEqual({
      runtime_thread_recreated_reason: 'replayed_from_transcript'
    })
    expect(fixture.log().find(entry => entry.received === 'thread/inject_items')).toMatchObject({
      threadId: 'thread-2',
      itemCount: 2
    })
    const secondTurn = fixture.log().filter(entry => entry.received === 'turn/start')[1]
    expect(secondTurn).toMatchObject({ threadId: 'thread-2', input: continuationInput })
    expect(fixture.statusUpdates.at(-1)?.status).toBe('succeeded')
  })
})

/**
 * Resolves with the first log entry that matches, or with `undefined` when the
 * session settles first.
 */
async function raceWithLog(
  run: Promise<unknown>,
  fixture: { log(): LogEntry[] },
  matches: (entry: LogEntry) => boolean
): Promise<LogEntry | undefined> {
  let settled = false
  void run.then(
    () => {
      settled = true
    },
    () => {
      settled = true
    }
  )
  const deadline = Date.now() + 15_000
  while (!settled && Date.now() < deadline) {
    const entry = fixture.log().find(matches)
    if (entry) return entry
    await Bun.sleep(10)
  }
  return fixture.log().find(matches)
}

function latestTurnStatuses(upserts: RecordedTurnUpsert[]): Array<[string, string, string]> {
  const latest = new Map<string, [string, string, string]>()
  for (const upsert of upserts) {
    latest.set(upsert.runtimeTurnId ?? '', [upsert.runtimeTurnId ?? '', upsert.kind ?? '', upsert.status ?? ''])
  }
  return [...latest.values()]
}

function parsedJSON(bytes: Uint8Array | undefined): JSONObject | undefined {
  return bytes ? jsonObjectFromBytes(bytes, 'test fixture json') : undefined
}

function sessionFixture(
  agentUID: string,
  scenario: FakeScenario,
  storedTurnItems: StoredTurnItem[] = []
): {
  prepared: PreparedCodexJobExecution
  opts: CodexJobOptions
  job: BackgroundAgentJobResponse
  statusUpdates: RecordedStatusUpdate[]
  turnUpserts: RecordedTurnUpsert[]
  log(): LogEntry[]
  cleanupCalls(): number
} {
  const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-session-'))
  roots.push(root)
  const agentHome = join(root, 'agent-home')
  const codexHome = join(root, 'codex-home')
  const projectRoot = join(root, 'project')
  const libraryRoot = join(root, 'library')
  const script = join(root, 'fake-app-server.ts')
  const flock = join(root, 'fake-flock')
  const scenarioPath = join(root, 'scenario.json')
  const logPath = join(root, 'requests.log')
  for (const path of [agentHome, codexHome, projectRoot, libraryRoot]) mkdirSync(path, { recursive: true })
  writeFileSync(scenarioPath, JSON.stringify(scenario))
  writeFakeAppServer(script)
  writeFileSync(flock, '#!/bin/sh\nset -eu\nshift 5\nexec "$@"\n', { mode: 0o755 })
  chmodSync(flock, 0o755)
  process.env.ANKOLE_FLOCK_BINARY = flock

  const statusUpdates: RecordedStatusUpdate[] = []
  const turnUpserts: RecordedTurnUpsert[] = []
  let cleanupCalls = 0
  const job = create(BackgroundAgentJobResponseSchema, {
    jobId: jobID,
    agentUid: agentUID,
    ownerSessionId: 'parent-session',
    status: 'queued',
    title: 'Prepare launch brief',
    task: 'Write and verify the launch brief.',
    attempts: 1,
    workspaceOwnerJobId: jobID,
    metadataJson: jsonBytes({})
  })
  const rpc = (async (method: unknown, payload: unknown) => {
    switch (method) {
      case rpcMethods.backgroundAgentJobStatusUpdate: {
        const request = payload as RecordedStatusUpdate
        statusUpdates.push(request)
        return create(BackgroundAgentJobResponseSchema, {
          ...job,
          status: request.status ?? '',
          runtimeThreadId: request.runtimeThreadId ?? ''
        })
      }
      case rpcMethods.backgroundAgentJobTurnUpsert: {
        const request = payload as RecordedTurnUpsert
        turnUpserts.push(request)
        return create(BackgroundAgentJobTurnUpsertResponseSchema, {
          jobId: request.jobId,
          turn: {
            id: `stored:${request.runtimeTurnId}`,
            attempt: request.attempt,
            runtimeThreadId: request.runtimeThreadId,
            runtimeTurnId: request.runtimeTurnId,
            kind: request.kind,
            status: request.status,
            revision: request.revision,
            startedAt: request.startedAt,
            completedAt: request.completedAt ?? ''
          }
        })
      }
      case rpcMethods.backgroundAgentJobTurnItemsList:
        return create(BackgroundAgentJobTurnItemsListResponseSchema, {
          jobId: jobID,
          items: storedTurnItems.map(entry => ({
            runtimeThreadId: 'stored-thread',
            runtimeTurnId: 'stored-turn',
            position: entry.position,
            itemKey: entry.itemKey,
            itemJson: jsonBytes(entry.item)
          })),
          nextCursor: ''
        })
      default:
        throw new Error(`unexpected RPC method: ${String(method)}`)
    }
  }) as RPCRequester

  const prepared: PreparedCodexJobExecution = {
    runtimeAcquire: {
      agentUID,
      agentHome,
      codexHome,
      aiGatewayBaseURL: 'http://gateway.test/v1',
      aiGatewayAPIKey: 'agent-key',
      sandbox: {
        cwd: root,
        codexCwd: root,
        commandArgv: [process.execPath, script],
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: agentHome,
          CODEX_HOME: codexHome,
          FAKE_SCENARIO: scenarioPath,
          FAKE_LOG: logPath
        }
      }
    },
    threadConfig: { model_provider: 'ankole_aigateway' },
    projection: {
      dynamicTools: [],
      quarantinedTools: [],
      handleToolCall: async () => ({ contentItems: [], success: false })
    },
    skills: {
      loadable: [],
      loader: {
        load: () => Promise.reject(new Error('no Skill is loadable in this fixture')),
        disable() {}
      },
      takeLoadedNames: () => [],
      mcpServers: []
    },
    project: { root: projectRoot },
    replaceLegacySkillThread: false,
    preparedAgentPlugins: prepareAgentPlugins({
      projectRoot,
      agentPlugins: [],
      agentHome,
      libraryRoot,
      initializeProject: false
    }),
    cleanup: async () => {
      cleanupCalls += 1
    }
  }
  const opts: CodexJobOptions = {
    agentsRoot: root,
    agentHome,
    workspaceRoot: projectRoot,
    userFilesRoot: join(agentHome, 'user-files'),
    builtinSkillsRoot: join(root, 'builtin-skills'),
    agentInstalledSkillsRoot: join(agentHome, 'installed-skills'),
    rpc,
    requestAIGatewayAPIKey: () => Promise.reject(new Error('the session does not request a key'))
  }

  return {
    prepared,
    opts,
    job,
    statusUpdates,
    turnUpserts,
    log: () =>
      existsSync(logPath)
        ? readFileSync(logPath, 'utf8')
            .split('\n')
            .filter(Boolean)
            .map(line => JSON.parse(line) as LogEntry)
        : [],
    cleanupCalls: () => cleanupCalls
  }
}

function turnStart(): TurnStart {
  return {
    workspace_id: 10_000,
    turn: {
      actor: { agent_uid: 'agent-1', session_id: `job:${jobID}` },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      queue_sequence: 1,
      type: 'background_agent_job.dispatch',
      source_event_id: 'background-agent-job-dispatch-1',
      payload_json: { data: { job_id: Number(jobID), owner_session_id: 'parent-session', attempts: 1 } }
    },
    model_ref: {
      profile: 'coding',
      provider_id: 'openai',
      provider_kind: 'openai',
      model: 'gpt-5.6-sol',
      provider_options: { reasoningEffort: 'high' },
      supports_parallel_tool_calls: true
    },
    request_context: {}
  }
}

/**
 * The fake follows the pinned app-server contract for the methods the session
 * uses. A `turn/start` that arrives while the compaction turn is active is
 * answered with a turn id and then produces no notification, which is how
 * Codex handles input that its Compact task cannot accept.
 */
function writeFakeAppServer(path: string): void {
  writeFileSync(
    path,
    `import { appendFileSync, readFileSync } from 'node:fs'
const scenario = JSON.parse(readFileSync(process.env.FAKE_SCENARIO, 'utf8'))
let buffer = ''
let threadCount = 0
let turnCount = 0
let compactionCount = 0
let activeCompactionTurn = undefined
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function log(entry) { appendFileSync(process.env.FAKE_LOG, JSON.stringify(entry) + '\\n') }
function handle(message) {
  const params = message.params ?? {}
  if (message.method === 'initialize') {
    log({ received: 'initialize' })
    return write({ id: message.id, result: { userAgent: 'fake-codex/1' } })
  }
  if (message.method === 'initialized') return log({ received: 'initialized' })
  if (message.method === 'thread/start') {
    threadCount += 1
    log({ received: 'thread/start', threadId: 'thread-' + threadCount })
    return write({ id: message.id, result: { thread: { id: 'thread-' + threadCount } } })
  }
  if (message.method === 'thread/resume') {
    log({ received: 'thread/resume', threadId: params.threadId })
    return write({ id: message.id, result: { thread: { id: params.threadId } } })
  }
  if (message.method === 'thread/inject_items') {
    log({ received: 'thread/inject_items', threadId: params.threadId, itemCount: params.items.length })
    return write({ id: message.id, result: {} })
  }
  if (message.method === 'turn/start') {
    const threadId = params.threadId
    const input = Array.isArray(params.input) ? params.input[0]?.text : ''
    if (activeCompactionTurn) {
      log({ received: 'turn/start', threadId, input, rejected: 'active_compaction_turn' })
      return write({ id: message.id, result: { turn: { id: 'rejected-' + (turnCount + 1), status: 'inProgress' } } })
    }
    turnCount += 1
    const turnId = 'turn-' + turnCount
    const outcome = scenario.turns[turnCount - 1]
    log({ received: 'turn/start', threadId, input })
    write({ id: message.id, result: { turn: { id: turnId, status: 'inProgress' } } })
    setTimeout(() => {
      write({ method: 'turn/started', params: { threadId, turn: { id: turnId, status: 'inProgress', items: [] } } })
      if (!outcome) return
      if (outcome.status === 'completed') {
        write({ method: 'item/completed', params: { threadId, turnId, item: { type: 'agentMessage', id: 'message-' + turnCount, text: outcome.text } } })
        write({ method: 'turn/completed', params: { threadId, turn: { id: turnId, status: 'completed' } } })
        return
      }
      write({ method: 'turn/completed', params: { threadId, turn: { id: turnId, status: 'failed', error: outcome.error } } })
    }, 5)
    return
  }
  if (message.method === 'thread/compact/start') {
    const threadId = params.threadId
    compactionCount += 1
    const turnId = 'turn-compact-' + compactionCount
    const compaction = scenario.compaction ?? { completeDelayMs: 0, status: 'completed' }
    activeCompactionTurn = turnId
    log({ received: 'thread/compact/start', threadId })
    write({ id: message.id, result: {} })
    setTimeout(() => {
      write({ method: 'turn/started', params: { threadId, turn: { id: turnId, status: 'inProgress', items: [] } } })
      write({ method: 'item/completed', params: { threadId, turnId, item: { type: 'contextCompaction', id: 'compaction-' + compactionCount } } })
      setTimeout(() => {
        activeCompactionTurn = undefined
        log({ emitted: 'compaction_turn_completed', turnId, status: compaction.status })
        const turn = compaction.status === 'completed'
          ? { id: turnId, status: 'completed' }
          : { id: turnId, status: 'failed', error: { message: 'compaction failed upstream' } }
        write({ method: 'turn/completed', params: { threadId, turn } })
      }, compaction.completeDelayMs)
    }, 5)
    return
  }
  if (message.method === 'thread/backgroundTerminals/list') return write({ id: message.id, result: { data: [] } })
  if (message.method === 'config/batchWrite') {
    log({ received: 'config/batchWrite' })
    return write({ id: message.id, result: {} })
  }
  if (message.id !== undefined) {
    log({ received: message.method })
    write({ id: message.id, result: {} })
  }
}
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  buffer += chunk
  let index = buffer.indexOf('\\n')
  while (index >= 0) {
    const line = buffer.slice(0, index).trim()
    buffer = buffer.slice(index + 1)
    if (line) handle(JSON.parse(line))
    index = buffer.indexOf('\\n')
  }
})
process.stdin.on('end', () => process.exit(0))
`
  )
}
