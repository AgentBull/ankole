import { HostedTool } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { afterEach, describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { mkdirAgentSync } from '../src/common/agent-user'
import { runCodexJob } from '../src/core/codex-runner'
import { create } from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { jsonBytes, jsonFromBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import {
  AgentConversationContextResponseSchema,
  AIGatewayAPIKeyResponseSchema,
  BackgroundAgentJobResponseSchema,
  BackgroundAgentJobTurnItemsListResponseSchema,
  BackgroundAgentJobTurnUpsertResponseSchema,
  RuntimeSkillSummarySchema,
  WorkerEnvResolveResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  type BackgroundAgentJobResponse,
  type RuntimeSkillSummary
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { type RPCRequester } from '../src/lanes/rpc_lane'
import { type RPCRequestInit } from '../src/lanes/rpc_contract'

type RecordedStatusUpdate = RPCRequestInit<'background_agent_job.status.update'> & {
  metadataJson?: Uint8Array
  resultJson?: Uint8Array
  errorJson?: Uint8Array
}
type RecordedTurnUpsert = RPCRequestInit<'background_agent_job.turn.upsert'> & {
  trajectoryJson?: Uint8Array
  turnItemsJson?: Uint8Array
  progressJson?: Uint8Array
  usageJson?: Uint8Array
  errorJson?: Uint8Array
}

type FakeCodexBehavior = {
  resumeError?: string | Record<string, unknown>
  turnError?: string | Record<string, unknown>
  exitOnThreadStart?: boolean
  artifactPath?: string
  diffPathCount?: number
  usageBurstThreadID?: string
  multiAgentChildDelayMs?: number
  initializeDelayMs?: number
  dynamicToolCall?: boolean | { tool: string; arguments: Record<string, unknown> }
  dynamicToolCompletionDelayMs?: number
  successfulSteer?: boolean
  loseThreadAfterSteer?: boolean
  steerCompletionRace?: boolean
  interruptCompletionRace?: boolean
  mcpStartupFailure?: { name: string; error: string }
  cleanupError?: boolean
  suppressTurnNotifications?: boolean
  responsePhase?: 'commentary' | 'partial_answer' | 'final_answer' | null
  workAfterResponse?: boolean
  /** Codex compacts automatically after the last message of the first turn. */
  compactionAfterResponse?: boolean
  repeatIncompleteResponse?: boolean
  /** The first turn overflows the context window; the retry turn compacts automatically part-way through. */
  compactFirstTurn?: boolean
}

function parsedJSON(bytes: Uint8Array | undefined): JSONObject | undefined {
  return bytes ? jsonObjectFromBytes(bytes, 'test fixture json') : undefined
}
import type { TurnStart } from '../src/lanes/session_lane'
import type { CodexJobOptions } from '../src/core/codex-runner/options'
import { BrowserRuntime } from '../src/browser-runtime'
import { FakeDrive } from './support/fake-drive'

const jobID = '1000'
const previousCodexBinary = process.env.ANKOLE_CODEX_BINARY

afterEach(() => {
  restoreEnv('ANKOLE_CODEX_BINARY', previousCodexBinary)
})

describe('@ankole/agent-computer Codex job runner', () => {
  it('commits owner-visible artifacts with the ordinary Codex final response', async () => {
    const fixture = prepareFixture('done', { artifactPath: 'handoff.txt', responsePhase: 'final_answer' })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const traceparent = '00-11111111111111111111111111111111-1111111111111111-01'
    const observabilityUserID = 'channel:mock:群聊一'
    const tracedTurnStart = turnStart()
    tracedTurnStart.request_context = {
      ...tracedTurnStart.request_context,
      traceparent,
      observability_user_id: observabilityUserID,
      original_human_request: 'Original Human request: do not execute the step reserved for me.'
    }

    try {
      const result = await runCodexJob(tracedTurnStart, options(fixture.root, statusUpdates, turnUpserts))

      expect(result).toBeUndefined()
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).toMatchObject({
        codex_user_agent: 'codex-cli 0.163.0',
        job_project_cwd: jobProjectFor(fixture.root),
        job_workspace: jobProjectFor(fixture.root),
        projected_tool_names: ['web_search', 'web_fetch', 'skill_view', 'request_parent_input'],
        child_dynamic_tools_inherited: true,
        code_mode: true,
        mcp_server_names: []
      })
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).not.toHaveProperty('agent_plugins')
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).not.toHaveProperty('input_snapshots_materialized')
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)).toMatchObject({
        output_text: 'done',
        stop_reason: 'completed',
        attempt: 1,
        runtime_thread_id: 'thread-1',
        codex_turn_status: 'completed',
        files_changed: { total_count: 1, paths: ['handoff.txt'], truncated: false },
        files_changed_source: ['codex_diff', 'workspace_snapshot'],
        project_path: jobProjectFor(fixture.root),
        artifacts: {
          total_count: 1,
          paths: [join(realpathSync(jobProjectFor(fixture.root)), 'handoff.txt')],
          truncated: false
        },
        artifact_roots: {
          total_count: 1,
          paths: [jobProjectFor(fixture.root)],
          truncated: false
        }
      })
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)).not.toHaveProperty('verification')
      expect(turnUpserts.some(update => update.status === 'completed')).toBe(true)
      expect(readFileSync(join(jobProjectFor(fixture.root), 'handoff.txt'), 'utf8')).toBe('artifact')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-input.txt'), 'utf8')).toBe(response().task)

      const threadStart = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'thread-start.json'), 'utf8'))
      expect(threadStart.config.developer_instructions).toContain('chats/mock:dm:alice/')
      expect(threadStart.developerInstructions).toBe(threadStart.config.developer_instructions)
      expect(threadStart.developerInstructions).toContain(tracedTurnStart.request_context!.original_human_request)
      expect(readFileSync(join(jobProjectFor(fixture.root), 'AGENTS.md'), 'utf8')).toContain('chats/mock:dm:alice/')
      expect(threadStart.config.model_providers.ankole_aigateway.http_headers).toMatchObject({
        traceparent,
        'x-ankole-observability-user-id': Buffer.from(observabilityUserID).toString('base64url')
      })
      const browserEnv = JSON.parse(
        readFileSync(join(jobProjectFor(fixture.root), 'browser-env.json'), 'utf8')
      ) as Record<string, string>
      expect(browserEnv).toMatchObject({
        ANKOLE_BROWSER_SESSION: 'default',
        ANKOLE_BROWSER_ARTIFACT_ROOT: join(jobProjectFor(fixture.root), 'browser'),
        SAFE_VALUE: 'kept'
      })
      expect(browserEnv.ANKOLE_BROWSER_SOCKET).toBe(join(fixture.root, 'browser-socket', 'browser.sock'))
      expect(browserEnv.ANKOLE_BROWSER_MATERIAL).toStartWith(
        join(fixture.root, 'browser-runtime', 'browser', 'materials', 'br_')
      )
      expect(browserEnv.ANKOLE_BROWSER_ROUTE).toMatch(/^br_[A-Za-z0-9_-]{16,128}$/)
      expect(browserEnv).not.toHaveProperty('BROWSER_BACKEND_JSON')
      const routeRecord = JSON.parse(
        readFileSync(join(jobProjectFor(fixture.root), '.ankole', 'browser-route.json'), 'utf8')
      ) as Record<string, unknown>
      expect(routeRecord.route_id).toBe(browserEnv.ANKOLE_BROWSER_ROUTE)
      expect(Object.keys(routeRecord).sort()).toEqual([
        'immutable_key',
        'material_generation',
        'material_hash',
        'route_id',
        'version'
      ])
      expect(readdirSync(join(fixture.root, 'browser-runtime', 'browser', 'materials'))).toEqual([])
    } finally {
      fixture.cleanup()
    }
  })

  it('lists a file written outside the Codex diff from the workspace snapshot', async () => {
    const fixture = prepareFixture('done', {
      artifactPath: 'shell-report.md',
      diffPathCount: 0,
      responsePhase: 'final_answer'
    })
    const statusUpdates: RecordedStatusUpdate[] = []

    try {
      await runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      const result = parsedJSON(statusUpdates.at(-1)?.resultJson)
      expect(result?.files_changed).toEqual({ total_count: 1, paths: ['shell-report.md'], truncated: false })
      expect(result?.files_changed_source).toEqual(['workspace_snapshot'])
      expect(result?.artifacts).toEqual({
        total_count: 1,
        paths: [join(realpathSync(jobProjectFor(fixture.root)), 'shell-report.md')],
        truncated: false
      })
    } finally {
      fixture.cleanup()
    }
  })

  it('uses provider-hosted web search without projecting the local duplicate', async () => {
    const fixture = prepareFixture('searched')
    const statusUpdates: RecordedStatusUpdate[] = []
    const start = turnStart()
    start.request_context = {
      ...start.request_context,
      ai_agent: { provider_hosted: { web_search: true } }
    }
    start.hosted_tools = [HostedTool.WEB_SEARCH]

    try {
      const result = await runCodexJob(start, options(fixture.root, statusUpdates, []))

      expect(result).toBeUndefined()
      expect(parsedJSON(statusUpdates[0]?.metadataJson)?.projected_tool_names).toEqual([
        'web_fetch',
        'skill_view',
        'request_parent_input'
      ])
      expect(readFileSync(join(jobProjectFor(fixture.root), '.codex', 'config.toml'), 'utf8')).toContain(
        'web_search = "live"'
      )
    } finally {
      fixture.cleanup()
    }
  })

  it('keeps a committed terminal Job successful when app-server cleanup fails', async () => {
    const fixture = prepareFixture('done before cleanup failure', { cleanupError: true })
    const statusUpdates: RecordedStatusUpdate[] = []

    try {
      const result = await runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))

      expect(result).toBeUndefined()
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)?.output_text).toBe('done before cleanup failure')
    } finally {
      fixture.cleanup()
    }
  })

  it('durably retries a Codex turn that accepts turn/start but produces no runtime progress', async () => {
    const fixture = prepareFixture('never delivered', { suppressTurnNotifications: true })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const opts = options(fixture.root, statusUpdates, turnUpserts)
    opts.firstCodexProgressTimeoutMs = 20

    try {
      await expect(runCodexJob(turnStart(), opts)).rejects.toMatchObject({
        name: 'CodexTurnNoProgressError',
        code: 'codex_turn_no_progress',
        retryable: true
      })
      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
      expect(turnUpserts.at(-1)?.status).toBe('failed')
      expect(parsedJSON(turnUpserts.at(-1)?.errorJson)?.summary).toContain('no runtime progress')
    } finally {
      fixture.cleanup()
    }
  })

  it('bounds a hostile aggregate diff before Turn progress and artifact inspection', async () => {
    const fixture = prepareFixture('done after a hostile diff', { diffPathCount: 50_000 })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []

    try {
      await runCodexJob(turnStart(), options(fixture.root, statusUpdates, turnUpserts))

      const result = parsedJSON(statusUpdates.at(-1)?.resultJson)
      expect(result?.files_changed).toMatchObject({ total_count: 50_000, truncated: true })
      expect((result?.files_changed as JSONObject | undefined)?.paths).toHaveLength(32)
      expect(result?.artifacts).toMatchObject({ total_count: 50_000, truncated: true })
      expect(result?.artifact_roots).toMatchObject({ total_count: 1, truncated: false })

      const completedTurn = [...turnUpserts].reverse().find(update => update.status === 'completed')
      const progress = parsedJSON(completedTurn?.progressJson)
      expect(progress?.files_changed).toHaveLength(32)
      expect(new TextEncoder().encode(JSON.stringify(progress?.files_changed)).byteLength).toBeLessThanOrEqual(8_192)
    } finally {
      fixture.cleanup()
    }
  })

  it('asks Codex once for a missing final response and then succeeds', async () => {
    const fixture = prepareFixture('')
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []

    try {
      await runCodexJob(turnStart(), options(fixture.root, statusUpdates, turnUpserts))

      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)?.output_text).toBe('final response after retry')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('2')
    } finally {
      fixture.cleanup()
    }
  })

  for (const [name, behavior] of [
    ['commentary', { responsePhase: 'commentary' }],
    ['partial answer', { responsePhase: 'partial_answer' }],
    ['unphased message followed by work', { responsePhase: null, workAfterResponse: true }],
    ['final message followed by work', { responsePhase: 'final_answer', workAfterResponse: true }]
  ] as const) {
    it(`requests a final report after ${name}`, async () => {
      const fixture = prepareFixture('I will read the playbook now.', behavior)
      const statusUpdates: RecordedStatusUpdate[] = []

      try {
        await runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))

        expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
        expect(parsedJSON(statusUpdates.at(-1)?.resultJson)?.output_text).toBe('final response after retry')
        expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('2')
      } finally {
        fixture.cleanup()
      }
    })
  }

  it('keeps an unphased final message when only an automatic compaction follows it', async () => {
    const fixture = prepareFixture('Final report before compaction.', {
      responsePhase: null,
      compactionAfterResponse: true
    })
    const statusUpdates: RecordedStatusUpdate[] = []

    try {
      await runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)?.output_text).toBe('Final report before compaction.')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('1')
    } finally {
      fixture.cleanup()
    }
  })

  it('fails after one report retry if Codex still returns only commentary', async () => {
    const fixture = prepareFixture('I will inspect the sources.', {
      responsePhase: 'commentary',
      repeatIncompleteResponse: true
    })
    const statusUpdates: RecordedStatusUpdate[] = []

    try {
      await runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'failed'])
      expect(parsedJSON(statusUpdates.at(-1)?.errorJson)?.code).toBe('codex_empty_report')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('2')
    } finally {
      fixture.cleanup()
    }
  })

  it('keeps the lead turn alive through cumulative usage updates from a child thread', async () => {
    const fixture = prepareFixture('completed after child usage updates', {
      usageBurstThreadID: 'child-thread',
      responsePhase: null
    })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []

    try {
      const result = await runCodexJob(turnStart(), options(fixture.root, statusUpdates, turnUpserts))

      expect(result).toBeUndefined()
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)?.output_text).toBe('completed after child usage updates')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('1')
      expect(turnUpserts.every(update => parsedJSON(update.errorJson)?.code !== 'codex_no_progress')).toBe(true)
    } finally {
      fixture.cleanup()
    }
  })

  it('persists a real MultiAgentV2 child Turn before it commits the lead result', async () => {
    const fixture = prepareFixture('completed after child work', { multiAgentChildDelayMs: 50 })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []

    try {
      await runCodexJob(turnStart(), options(fixture.root, statusUpdates, turnUpserts))

      expect(
        JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'thread-start.json'), 'utf8')).experimentalRawEvents
      ).toBe(true)
      expect(turnUpserts.filter(update => update.runtimeThreadId === 'child-thread').at(-1)?.status).toBe('completed')
      const recordedItems = turnUpserts
        .flatMap(update => (update.turnItemsJson ? [new TextDecoder().decode(update.turnItemsJson)] : []))
        .join('')
      expect(recordedItems).toContain('"spawn_agent"')
      expect(recordedItems).toContain('"collaboration"')
      expect(recordedItems).toContain('child-thread')
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)?.output_text).toBe('completed after child work')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('1')
    } finally {
      fixture.cleanup()
    }
  })

  it('records the explicit compaction Turn as compaction and an automatic compaction inside an agent Turn as agent', async () => {
    const fixture = prepareFixture('unused: the first turn overflows', { compactFirstTurn: true })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const itemTypes = (turnID: string) =>
      turnUpserts
        .filter(update => update.runtimeTurnId === turnID && update.turnItemsJson)
        .flatMap(update => jsonFromBytes(update.turnItemsJson!) as Array<{ item: { type: string } }>)
        .map(entry => entry.item.type)

    try {
      const result = await runCodexJob(turnStart(), options(fixture.root, statusUpdates, turnUpserts))

      expect(result).toBeUndefined()
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)).toMatchObject({ output_text: 'final response after retry' })
      expect(existsSync(join(codexHomeFor(fixture.root), 'compact-start.json'))).toBe(true)
      const kindsByTurn = new Map<string, Set<string>>()
      for (const update of turnUpserts) {
        const turnID = update.runtimeTurnId ?? ''
        kindsByTurn.set(turnID, (kindsByTurn.get(turnID) ?? new Set()).add(update.kind ?? ''))
      }
      expect([...kindsByTurn].map(([turnID, kinds]) => [turnID, [...kinds]])).toEqual([
        ['turn-1', ['agent']],
        ['turn-compact', ['compaction']],
        ['turn-2', ['agent']]
      ])
      expect(turnUpserts.filter(update => update.runtimeTurnId === 'turn-1').at(-1)?.status).toBe('failed')
      expect(turnUpserts.filter(update => update.runtimeTurnId === 'turn-compact').at(-1)?.status).toBe('completed')
      expect(itemTypes('turn-compact')).toEqual(['contextCompaction'])
      expect(itemTypes('turn-2')).toEqual(['userMessage', 'contextCompaction', 'agentMessage'])
    } finally {
      fixture.cleanup()
    }
  })

  it('fails first preparation when the workspace template is absent from the current enabled catalog', async () => {
    const fixture = prepareFixture('unused')
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const opts = options(fixture.root, statusUpdates, turnUpserts, () =>
      create(BackgroundAgentJobResponseSchema, { ...response(), workspaceTemplateId: 'office' })
    )

    try {
      await expect(runCodexJob(turnStart(), opts)).rejects.toThrow(
        'Workspace template Agent Plugin is unavailable: office'
      )
      expect(statusUpdates).toEqual([])
      expect(turnUpserts).toEqual([])
    } finally {
      fixture.cleanup()
    }
  })

  it('prepares every current compatible standalone Skill and skips main-only Skills', async () => {
    const fixture = prepareFixture('done without the main-only Skill')
    const statusUpdates: RecordedStatusUpdate[] = []
    const jobAny = create(RuntimeSkillSummarySchema, {
      skillName: 'job-any',
      description: 'Runs in a Background Job.',
      sourceKind: 'builtin',
      relativePath: 'job-any',
      metadataJson: jsonBytes({ 'ankole-runtime': 'any' })
    })
    const mainOnly = create(RuntimeSkillSummarySchema, {
      skillName: 'main-only',
      description: 'Runs only in the main Agent.',
      sourceKind: 'builtin',
      relativePath: 'main-only',
      metadataJson: jsonBytes({ 'ankole-runtime': 'main' })
    })
    for (const name of ['job-any', 'main-only']) {
      const root = join(fixture.root, 'builtin-skills', name)
      mkdirSync(root, { recursive: true })
      writeFileSync(join(root, 'SKILL.md'), `---\nname: ${name}\ndescription: Test.\n---\n`)
    }
    mkdirSync(join(fixture.root, 'builtin-skills', 'job-any', 'agents'), { recursive: true })
    writeFileSync(
      join(fixture.root, 'builtin-skills', 'job-any', 'agents', 'openai.yaml'),
      'dependencies:\n  tools:\n    - type: mcp\n      value: job-data\n      transport: streamable_http\n      url: https://mcp.example.test/rpc\n'
    )
    const opts = options(fixture.root, statusUpdates, [], undefined, undefined, undefined, [jobAny, mainOnly])

    try {
      await runCodexJob(turnStart([jobAny, mainOnly]), opts)

      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(parsedJSON(statusUpdates[0]?.metadataJson)?.mcp_server_names).toEqual(['job-data'])
      const agents = readFileSync(join(jobProjectFor(fixture.root), 'AGENTS.md'), 'utf8')
      expect(agents).toContain('job-any')
      expect(agents).not.toContain('main-only')
      expect(existsSync(join(jobProjectFor(fixture.root), '.agents', 'skills'))).toBe(false)
      const runtimeEnv = JSON.parse(
        readFileSync(join(jobProjectFor(fixture.root), 'browser-env.json'), 'utf8')
      ) as Record<string, string>
      expect(runtimeEnv.MCPORTER_CONFIG).toStartWith(`${join(jobProjectFor(fixture.root), 'temp')}/ankole-mcporter-`)
      expect(JSON.parse(runtimeEnv.MCPORTER_CONFIG_CONTENT)).toMatchObject({
        imports: [],
        mcpServers: { 'job-data': { baseUrl: 'https://mcp.example.test/rpc' } }
      })
      expect(existsSync(runtimeEnv.MCPORTER_CONFIG)).toBe(false)
    } finally {
      fixture.cleanup()
    }
  })

  it('reports an optional native MCP startup failure without failing the Job', async () => {
    const fixture = prepareFixture('done without optional MCP', {
      mcpStartupFailure: {
        name: 'optional-server',
        error: `Optional MCP server failed to start: ${'x'.repeat(3_000)}`
      }
    })
    const statusUpdates: RecordedStatusUpdate[] = []
    const warnings: Array<{ event: string; message: string; fields?: JSONObject }> = []
    const opts = options(fixture.root, statusUpdates, [])
    opts.logger = {
      info() {},
      warning(event, message, fields) {
        warnings.push({ event, message, fields })
      }
    }

    try {
      await runCodexJob(turnStart(), opts)

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(warnings).toHaveLength(1)
      expect(warnings[0]).toMatchObject({
        event: 'worker.codex_mcp_server_unavailable',
        message: 'Codex MCP server is unavailable',
        fields: { server: 'optional-server', status: 'failed' }
      })
      const error = String(warnings[0]?.fields?.error)
      expect(new TextEncoder().encode(error).byteLength).toBeLessThanOrEqual(2_048)
      expect(error).toEndWith('...[truncated]')
    } finally {
      fixture.cleanup()
    }
  })

  it('replaces an unknown persisted thread once and records the new durable anchor', async () => {
    const fixture = prepareFixture('done after recovery', { resumeError: 'No rollout found for thread' })

    try {
      await runCodexJob(turnStart(), options(fixture.root, [], []))

      const statusUpdates: RecordedStatusUpdate[] = []
      const opts = options(fixture.root, statusUpdates, [], () =>
        create(BackgroundAgentJobResponseSchema, {
          ...response(),
          status: 'running',
          attempts: 2,
          runtimeThreadId: 'missing-thread'
        })
      )

      await runCodexJob(turnStart(), opts)

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(statusUpdates[0]).toMatchObject({ runtimeThreadId: 'thread-1' })
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).toMatchObject({
        runtime_checkpoint_recreated: true,
        runtime_checkpoint_recovery: 'new_thread_from_bounded_history'
      })
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)?.runtime_thread_id).toBe('thread-1')
    } finally {
      fixture.cleanup()
    }
  })

  it('replays the original task after a crash between the durable thread anchor and the first turn', async () => {
    const fixture = prepareFixture('done after crash recovery', { resumeError: 'No rollout found for thread' })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    let currentJob = response()
    let crashAfterAnchor = true

    try {
      const opts = options(
        fixture.root,
        statusUpdates,
        turnUpserts,
        () => currentJob,
        update => {
          if (!crashAfterAnchor || update.status !== 'running' || !update.runtimeThreadId) return
          crashAfterAnchor = false
          currentJob = create(BackgroundAgentJobResponseSchema, {
            ...currentJob,
            status: 'running',
            attempts: 2,
            runtimeThreadId: update.runtimeThreadId
          })
          throw new Error('simulated worker crash after durable thread anchor')
        }
      )

      await expect(runCodexJob(turnStart(), opts)).rejects.toThrow('simulated worker crash after durable thread anchor')
      expect(currentJob.runtimeThreadId).toBe('thread-1')
      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
      expect(turnUpserts).toEqual([])
      expect(() => readFileSync(join(codexHomeFor(fixture.root), 'turn-input.txt'), 'utf8')).toThrow()

      await runCodexJob(turnStart(), opts)

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'running', 'succeeded'])
      expect(parsedJSON(statusUpdates[1]?.metadataJson)).toMatchObject({
        runtime_checkpoint_recreated: true,
        runtime_checkpoint_recovery: 'new_thread_from_bounded_history'
      })
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-input.txt'), 'utf8')).toContain(response().task)
    } finally {
      fixture.cleanup()
    }
  })

  it('hands a structured transient resume failure back to the durable Job lease', async () => {
    const fixture = prepareFixture('done before retry', {
      resumeError: {
        code: -32001,
        message: 'request failed without a retry keyword',
        data: { codexErrorInfo: 'serverOverloaded' }
      }
    })

    try {
      await runCodexJob(turnStart(), options(fixture.root, [], []))
      const opts = options(fixture.root, [], [], () =>
        create(BackgroundAgentJobResponseSchema, {
          ...response(),
          status: 'running',
          attempts: 2,
          runtimeThreadId: 'thread-1'
        })
      )

      await expect(runCodexJob(turnStart(), opts)).rejects.toMatchObject({
        code: 'codex_job_transient',
        retryable: true
      })
    } finally {
      fixture.cleanup()
    }
  })

  it('hands the same retryable runtime loss when the app-server exits before root-thread registration', async () => {
    const fixture = prepareFixture('never delivered', { exitOnThreadStart: true })

    try {
      await expect(runCodexJob(turnStart(), options(fixture.root, [], []))).rejects.toMatchObject({
        code: 'runtime_lost',
        retryable: true
      })
    } finally {
      fixture.cleanup()
    }
  })

  it('hands an exhausted AIGateway credential pool back without a local Codex retry', async () => {
    const fixture = prepareFixture('must not run', {
      turnError: {
        codexErrorInfo: 'usageLimitExceeded',
        message: 'AIGateway credential pool exhausted. retry_at=2026-07-29T08:15:00Z'
      }
    })
    const statusUpdates: RecordedStatusUpdate[] = []

    try {
      await expect(runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))).rejects.toMatchObject({
        code: 'credential_pool_exhausted',
        retryable: true,
        status: 429,
        retryAt: '2026-07-29T08:15:00.000Z',
        details: { retry_at: '2026-07-29T08:15:00.000Z' }
      })
      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('1')
    } finally {
      fixture.cleanup()
    }
  })

  it('ends the Job turn on an Agent token quota rejection without a local Codex retry', async () => {
    // Codex emits one terminal usage-limit error for the gateway rejection.
    const fixture = prepareFixture('must not run', {
      turnError: {
        codexErrorInfo: 'usageLimitExceeded',
        message: "You've hit your usage limit. retry_at=2030-09-16T08:00:00Z",
        additionalDetails: null
      }
    })
    const statusUpdates: RecordedStatusUpdate[] = []

    try {
      await expect(runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))).rejects.toMatchObject({
        code: 'credential_pool_exhausted',
        retryable: true,
        status: 429
      })
      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('1')
    } finally {
      fixture.cleanup()
    }
  })

  it('returns an unavailable dynamic tool result without stalling the Codex turn', async () => {
    const fixture = prepareFixture('done after unsupported tool', { dynamicToolCall: true })
    const statusUpdates: RecordedStatusUpdate[] = []

    try {
      await runCodexJob(turnStart(), options(fixture.root, statusUpdates, []))

      const response = JSON.parse(
        readFileSync(join(codexHomeFor(fixture.root), 'tool-response.json'), 'utf8')
      ) as Record<string, unknown>
      expect(response.id).toBe(101)
      expect(response.result).toMatchObject({ success: false })
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
    } finally {
      fixture.cleanup()
    }
  })

  it('uses a waiting Job message as the exact causal continuation input', async () => {
    const fixture = prepareFixture('done after the answer')
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const currentJob = create(BackgroundAgentJobResponseSchema, {
      ...response(),
      status: 'running',
      attempts: 2,
      runtimeThreadId: 'thread-1'
    })
    const continuation = messageTurnStart()
    continuation.request_context = {
      ...continuation.request_context,
      original_human_request: 'Original new Human request: use the operator audience; my reserved step remains mine.'
    }

    try {
      await runCodexJob(
        continuation,
        options(fixture.root, statusUpdates, turnUpserts, () => currentJob)
      )

      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-input.txt'), 'utf8')).toBe(
        'The audience is operators.'
      )
      const persistedItems = turnUpserts
        .flatMap(request => (request.turnItemsJson ? [new TextDecoder().decode(request.turnItemsJson)] : []))
        .join('\n')
      expect(persistedItems).toContain(`client:${continuation.signal.signal_id}`)
      expect(persistedItems).not.toContain('"answers"')
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      const resumed = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'thread-resume.json'), 'utf8'))
      expect(resumed.config.developer_instructions).toContain('chats/mock:dm:alice/')
      expect(resumed.config.developer_instructions).toContain(continuation.request_context!.original_human_request)
      const injected = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'inject-items.json'), 'utf8'))
      expect(injected.items).toEqual([
        {
          type: 'message',
          role: 'developer',
          content: [{ type: 'input_text', text: resumed.config.developer_instructions }]
        }
      ])
    } finally {
      fixture.cleanup()
    }
  })

  it('runs a respawned Job in the source workspace and sends only the new message', async () => {
    const fixture = prepareFixture('done after respawn')
    const statusUpdates: RecordedStatusUpdate[] = []
    const workspaceOwnerJobID = '1001'
    const sourceJobID = '1002'
    const sourceWorkspace = jobProjectFor(fixture.root, workspaceOwnerJobID)
    rmSync(jobProjectFor(fixture.root), { recursive: true, force: true })
    mkdirSync(sourceWorkspace, { recursive: true })
    writeFileSync(join(sourceWorkspace, 'source-artifact.txt'), 'retained')
    const currentJob = create(BackgroundAgentJobResponseSchema, {
      ...response(),
      task: '  Improve the PDF layout.  ',
      runtimeThreadId: 'thread-1',
      continuedFromJobId: sourceJobID,
      workspaceOwnerJobId: workspaceOwnerJobID
    })

    try {
      await runCodexJob(
        turnStart(),
        options(fixture.root, statusUpdates, [], () => currentJob)
      )

      expect(readFileSync(join(sourceWorkspace, 'source-artifact.txt'), 'utf8')).toBe('retained')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-input.txt'), 'utf8')).toBe(
        '  Improve the PDF layout.  '
      )
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).toMatchObject({
        job_project_cwd: sourceWorkspace,
        job_workspace: sourceWorkspace
      })
      expect(existsSync(jobProjectFor(fixture.root))).toBe(false)
    } finally {
      fixture.cleanup()
    }
  })

  it('replays the stored transcript into a replacement thread when a respawn cannot resume natively', async () => {
    const fixture = prepareFixture('done after replay', { resumeError: 'No rollout found for thread' })
    const statusUpdates: RecordedStatusUpdate[] = []
    const workspaceOwnerJobID = '1001'
    mkdirAgentSync(jobProjectFor(fixture.root, workspaceOwnerJobID))
    const currentJob = create(BackgroundAgentJobResponseSchema, {
      ...response(),
      task: 'Retry the failed work.',
      runtimeThreadId: 'missing-source-thread',
      metadataJson: jsonBytes({ legacy_thread_replay: true }),
      continuedFromJobId: '1002',
      workspaceOwnerJobId: workspaceOwnerJobID
    })

    try {
      await runCodexJob(
        turnStart(),
        options(fixture.root, statusUpdates, [], () => currentJob, undefined, undefined, [], undefined, [
          {
            position: 0,
            itemKey: 'client:event-0',
            item: { type: 'userMessage', id: 'user-0', content: [{ type: 'text', text: '源任务原文' }] }
          },
          {
            position: 1,
            itemKey: 'command-0',
            item: {
              type: 'commandExecution',
              id: 'command-0',
              command: 'printf source',
              cwd: '/workdir',
              status: 'completed',
              aggregatedOutput: 'source',
              exitCode: 0,
              durationMs: 1
            }
          },
          {
            position: 2,
            itemKey: 'message-0',
            item: { type: 'agentMessage', id: 'message-0', text: 'SOURCE_DONE' }
          }
        ])
      )

      const injected = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'inject-items.json'), 'utf8'))
      expect(injected.items).toEqual([
        { type: 'message', role: 'user', content: [{ type: 'input_text', text: '源任务原文' }] },
        expect.objectContaining({ type: 'function_call', name: 'shell', call_id: 'command-0' }),
        expect.objectContaining({ type: 'function_call_output', call_id: 'command-0' }),
        { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'SOURCE_DONE' }] }
      ])
      expect(readFileSync(join(codexHomeFor(fixture.root), 'turn-input.txt'), 'utf8')).toBe('Retry the failed work.')
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).toMatchObject({
        runtime_checkpoint_recreated: true,
        runtime_checkpoint_recovery: 'replayed_from_transcript',
        legacy_thread_replay: false
      })
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
    } finally {
      fixture.cleanup()
    }
  })

  it('continues a respawn from the durable Workspace when no stored transcript exists', async () => {
    const fixture = prepareFixture('done after rebuild', { resumeError: 'No rollout found for thread' })
    const statusUpdates: RecordedStatusUpdate[] = []
    const workspaceOwnerJobID = '1001'
    mkdirAgentSync(jobProjectFor(fixture.root, workspaceOwnerJobID))
    const currentJob = create(BackgroundAgentJobResponseSchema, {
      ...response(),
      task: 'Retry the failed work.',
      runtimeThreadId: 'missing-source-thread',
      metadataJson: jsonBytes({ legacy_thread_replay: true }),
      continuedFromJobId: '1002',
      workspaceOwnerJobId: workspaceOwnerJobID,
      resultOutputText: `SOURCE_DONE: created context-marker.txt${'界'.repeat(20000)}`
    })

    const currentTurn = turnStart()
    currentTurn.request_context = {
      ...currentTurn.request_context,
      original_human_request: 'Original Human request survives lost threads and continuation summaries.'
    }
    try {
      await runCodexJob(
        currentTurn,
        options(fixture.root, statusUpdates, [], () => currentJob)
      )

      const turnInputText = readFileSync(join(codexHomeFor(fixture.root), 'turn-input.txt'), 'utf8')
      expect(turnInputText).toContain('Retry the failed work.')
      expect(turnInputText).toContain('The previous Codex thread could not be resumed')
      expect(turnInputText).toContain('This Job continues terminal Job 1002')
      expect(turnInputText).toContain(currentJob.resultOutputText)
      expect(existsSync(join(codexHomeFor(fixture.root), 'inject-items.json'))).toBe(false)
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).toMatchObject({
        runtime_checkpoint_recreated: true,
        runtime_checkpoint_recovery: 'new_thread_from_bounded_history'
      })
      const replacement = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'thread-start.json'), 'utf8'))
      expect(replacement.config.developer_instructions).toContain(currentTurn.request_context!.original_human_request)
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
    } finally {
      fixture.cleanup()
    }
  })

  it('rebuilds the thread after a mid-run thread loss instead of failing the respawn', async () => {
    const fixture = prepareFixture('recovered', { turnError: 'No rollout found for thread' })
    const statusUpdates: RecordedStatusUpdate[] = []
    const workspaceOwnerJobID = '1001'
    mkdirAgentSync(jobProjectFor(fixture.root, workspaceOwnerJobID))
    const currentJob = create(BackgroundAgentJobResponseSchema, {
      ...response(),
      task: 'Retry the failed work.',
      runtimeThreadId: 'thread-1',
      continuedFromJobId: '1002',
      workspaceOwnerJobId: workspaceOwnerJobID
    })

    try {
      await runCodexJob(
        turnStart(),
        options(fixture.root, statusUpdates, [], () => currentJob)
      )

      // The first turn fails with an unknown thread, one replacement thread is
      // allowed, and the fake keeps failing, so the bounded ladder commits the
      // turn failure as the Job outcome instead of throwing a refusal.
      expect(statusUpdates.at(-1)?.status).toBe('failed')
      expect(Number(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8'))).toBeGreaterThan(1)
    } finally {
      fixture.cleanup()
    }
  })

  it('treats no active turn to steer as a completion race', async () => {
    const fixture = prepareFixture('done while steering', { steerCompletionRace: true })
    const statusUpdates: RecordedStatusUpdate[] = []
    const opts = options(fixture.root, statusUpdates, [])
    let polled = false
    opts.pollSteering = () => {
      if (polled) return []
      polled = true
      return [steerUpdate()]
    }

    try {
      await runCodexJob(turnStart(), opts)

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(statusUpdates.at(-1)?.appliedSignalIds).not.toContain(steerUpdate().signal?.signal_id)
    } finally {
      fixture.cleanup()
    }
  })

  it('persists the causal steer trajectory and acknowledges it in the terminal commit', async () => {
    const fixture = prepareFixture('done after steering', { successfulSteer: true })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const opts = options(fixture.root, statusUpdates, turnUpserts)
    const update = steerUpdate()
    const originalRequest = `<original_human_request>\n${JSON.stringify({
      message_id: 'new-human-message',
      text: 'Keep my action reserved for me.\nUse the new language.'
    })}\n</original_human_request>`
    Object.assign(update.signal.payload_json, { original_human_request: originalRequest })
    let polled = false
    opts.pollSteering = () => {
      if (polled) return []
      polled = true
      return [update]
    }

    try {
      await runCodexJob(turnStart(), opts)

      expect(readFileSync(join(codexHomeFor(fixture.root), 'steer-input.txt'), 'utf8')).toBe(
        `${originalRequest}\n\nDelegated message:\nUse the latest operator guidance.`
      )
      const eventID = steerUpdate().signal!.signal_id
      expect(
        turnUpserts.some(
          request =>
            request.turnItemsJson && new TextDecoder().decode(request.turnItemsJson).includes(`client:${eventID}`)
        )
      ).toBe(true)
      expect(statusUpdates.at(-1)?.appliedSignalIds).toContain(eventID)
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
    } finally {
      fixture.cleanup()
    }
  })

  it('keeps an acknowledged Human steer in the first replacement-thread instructions', async () => {
    const fixture = prepareFixture('done after steered thread loss', {
      successfulSteer: true,
      loseThreadAfterSteer: true
    })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const opts = options(fixture.root, statusUpdates, turnUpserts)
    const current = turnStart()
    current.request_context = { ...current.request_context, original_human_request: 'Original request A.' }
    const update = steerUpdate()
    Object.assign(update.signal.payload_json, {
      original_human_request: 'Original request B: preserve my reserved action.'
    })
    let polled = false
    opts.pollSteering = () => (polled ? [] : ((polled = true), [update]))
    try {
      await runCodexJob(current, opts)
      const replacement = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'thread-start.json'), 'utf8'))
      expect(replacement.developerInstructions).toContain('Original request B: preserve my reserved action.')
      expect(replacement.developerInstructions).not.toContain('Original request A.')
      expect(replacement.developerInstructions).toContain('chats/mock:dm:alice/')
      expect(Number(readFileSync(join(codexHomeFor(fixture.root), 'turn-count.txt'), 'utf8'))).toBe(2)
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
    } finally {
      fixture.cleanup()
    }
  })

  it('loads a prompt-hidden Skill and notifies the active Job once after it becomes disabled', async () => {
    const fixture = prepareFixture('done after Skill disable', {
      dynamicToolCall: { tool: 'skill_view', arguments: { name: 'pdf' } },
      dynamicToolCompletionDelayMs: 400,
      successfulSteer: true
    })
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const pdf = create(RuntimeSkillSummarySchema, {
      skillName: 'pdf',
      description: 'Test PDF Skill.',
      sourceKind: 'builtin',
      relativePath: 'pdf',
      metadataJson: jsonBytes({ 'ankole-runtime': 'any', brain_recall_only: true })
    })
    const skillRoot = join(fixture.root, 'builtin-skills', 'pdf')
    mkdirSync(skillRoot, { recursive: true })
    writeFileSync(join(skillRoot, 'SKILL.md'), '---\nname: pdf\ndescription: Test PDF Skill.\n---\n')
    const overlay = 'Overlay v1.'
    const opts = options(
      fixture.root,
      statusUpdates,
      turnUpserts,
      () => create(BackgroundAgentJobResponseSchema, { ...response([pdf]), task: 'Load the pdf Skill for this Job.' }),
      undefined,
      undefined,
      [pdf],
      () => overlay
    )
    let polled = false
    opts.pollDisabledSkills = () => {
      if (polled) return []
      polled = true
      return ['pdf']
    }
    try {
      await runCodexJob(turnStart([pdf]), opts)

      expect(readFileSync(join(jobProjectFor(fixture.root), 'AGENTS.md'), 'utf8')).not.toContain('Test PDF Skill.')
      expect(readFileSync(join(codexHomeFor(fixture.root), 'steer-input.txt'), 'utf8')).toContain('pdf')
      expect(
        turnUpserts.some(update => {
          const skillsUsed = parsedJSON(update.progressJson)?.skills_used
          return Array.isArray(skillsUsed) && skillsUsed.includes('pdf')
        })
      ).toBe(true)
      const skillDisableItems = turnUpserts.filter(update =>
        new TextDecoder().decode(update.turnItemsJson ?? new Uint8Array()).includes('skill-disabled:pdf')
      )
      expect(skillDisableItems).toHaveLength(1)
      const toolResponse = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'tool-response.json'), 'utf8')) as {
        result?: { contentItems?: Array<{ text?: string }> }
      }
      expect(toolResponse.result?.contentItems?.[0]?.text).toContain('Overlay v1.')
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
    } finally {
      fixture.cleanup()
    }
  })

  it('migrates a pre-upgrade Job to skill_view and rejects its now-disabled Skill', async () => {
    const fixture = prepareFixture('done after legacy Skill migration', {
      dynamicToolCall: { tool: 'skill_view', arguments: { name: 'pdf' } }
    })
    const statusUpdates: RecordedStatusUpdate[] = []
    const pdf = create(RuntimeSkillSummarySchema, {
      skillName: 'pdf',
      description: 'Disabled PDF Skill.',
      sourceKind: 'builtin',
      relativePath: 'pdf',
      metadataJson: jsonBytes({ 'ankole-runtime': 'any' })
    })
    const ordinary = create(RuntimeSkillSummarySchema, {
      skillName: 'ordinary',
      description: 'Current Background Job Skill.',
      sourceKind: 'builtin',
      relativePath: 'ordinary',
      metadataJson: jsonBytes({ 'ankole-runtime': 'any' })
    })
    const jobProject = jobProjectFor(fixture.root)
    const originalAgents = '# Existing Job guidance\n\nKeep this operator constraint.\n'
    writeFileSync(join(jobProject, 'AGENTS.md'), originalAgents)
    mkdirSync(join(jobProject, '.agents', 'skills', 'pdf'), { recursive: true })
    writeFileSync(join(jobProject, '.agents', 'skills', 'pdf', 'SKILL.md'), '# Stale PDF Skill\n')
    mkdirSync(join(jobProject, '.ankole', 'agent-plugins', 'legacy'), { recursive: true })
    writeFileSync(join(jobProject, '.ankole', 'agent-plugins', 'legacy', 'plugin.json'), '{}\n')
    const ordinaryRoot = join(fixture.root, 'builtin-skills', 'ordinary')
    mkdirSync(ordinaryRoot, { recursive: true })
    writeFileSync(join(ordinaryRoot, 'SKILL.md'), '# Ordinary Skill\n')
    const persisted = create(BackgroundAgentJobResponseSchema, {
      ...response([pdf, ordinary]),
      status: 'running',
      attempts: 2,
      runtimeThreadId: 'legacy-thread'
    })
    const opts = options(fixture.root, statusUpdates, [], () => persisted, undefined, undefined, [ordinary])

    try {
      await runCodexJob(turnStart([ordinary]), opts)

      const agents = readFileSync(join(jobProject, 'AGENTS.md'), 'utf8')
      expect(agents.startsWith(originalAgents)).toBe(true)
      expect(agents).toContain('ankole-background-job-skill-view-v1=legacy-thread')
      expect(agents).toContain('    - ordinary:')
      expect(agents).toContain('Current Background Job Skill.')
      expect(agents).not.toContain('Disabled PDF Skill.')
      expect(existsSync(join(jobProject, '.agents', 'skills'))).toBe(false)
      expect(existsSync(join(jobProject, '.ankole', 'agent-plugins'))).toBe(false)
      expect(existsSync(join(codexHomeFor(fixture.root), 'thread-start.json'))).toBe(true)
      expect(parsedJSON(statusUpdates[0]?.metadataJson)?.runtime_checkpoint_recreated).toBe(true)
      expect(statusUpdates[0]?.runtimeThreadId).toBe('thread-1')
      const toolResponse = JSON.parse(readFileSync(join(codexHomeFor(fixture.root), 'tool-response.json'), 'utf8')) as {
        result?: { success?: boolean; contentItems?: Array<{ text?: string }> }
      }
      expect(toolResponse.result?.success).toBe(false)
      expect(toolResponse.result?.contentItems?.[0]?.text).toBe('skill is not enabled for this turn: pdf')
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
    } finally {
      fixture.cleanup()
    }
  })

  it('keeps a requested stop terminal when completion races a rejected interrupt', async () => {
    const fixture = prepareFixture('late completion after stop', { interruptCompletionRace: true })
    const statusUpdates: RecordedStatusUpdate[] = []
    const controller = new AbortController()
    const opts = options(fixture.root, statusUpdates, [])
    opts.abortSignal = controller.signal

    try {
      const run = runCodexJob(turnStart(), opts)
      await waitForFile(join(codexHomeFor(fixture.root), 'turn-count.txt'))
      controller.abort(new Error('operator requested stop'))
      await run

      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'stopped'])
      expect(parsedJSON(statusUpdates.at(-1)?.metadataJson)?.stop_reason).toBe('operator requested stop')
    } finally {
      fixture.cleanup()
    }
  })

  it('does not prepare or spawn Codex for a turn that was already stopped', async () => {
    const fixture = prepareFixture('must not run')
    const statusUpdates: RecordedStatusUpdate[] = []
    const controller = new AbortController()
    const opts = options(fixture.root, statusUpdates, [])
    opts.abortSignal = controller.signal
    controller.abort(new Error('operator stopped before preparation'))

    try {
      await expect(runCodexJob(turnStart(), opts)).rejects.toThrow('operator stopped before preparation')

      expect(statusUpdates).toEqual([])
      expect(existsSync(join(jobProjectFor(fixture.root), 'browser-env.json'))).toBe(false)
    } finally {
      fixture.cleanup()
    }
  })

  it('rejects a start without the Agent context before preparation', async () => {
    const fixture = prepareFixture('must not run')
    const statusUpdates: RecordedStatusUpdate[] = []
    const start = turnStart()
    delete start.agent_context
    try {
      await expect(runCodexJob(start, options(fixture.root, statusUpdates, []))).rejects.toThrow(
        'Job preparation requires the Agent context'
      )
      expect(statusUpdates).toEqual([])
      expect(existsSync(join(jobProjectFor(fixture.root), 'browser-env.json'))).toBe(false)
    } finally {
      fixture.cleanup()
    }
  })

  it('stops preparation at the first completed boundary after a control arrives', async () => {
    const fixture = prepareFixture('must not run')
    const statusUpdates: RecordedStatusUpdate[] = []
    const controller = new AbortController()
    const opts = options(fixture.root, statusUpdates, [], undefined, undefined, method => {
      if (method === 'background_agent_job.get') {
        controller.abort(new Error('operator stopped during preparation'))
      }
    })
    opts.abortSignal = controller.signal

    try {
      await expect(runCodexJob(turnStart(), opts)).rejects.toThrow('operator stopped during preparation')

      expect(statusUpdates).toEqual([])
      expect(existsSync(join(jobProjectFor(fixture.root), 'browser-env.json'))).toBe(false)
    } finally {
      fixture.cleanup()
    }
  })

  it('stops after initialization without creating a Codex thread or turn', async () => {
    const fixture = prepareFixture('must not run', { initializeDelayMs: 50 })
    const statusUpdates: RecordedStatusUpdate[] = []
    const controller = new AbortController()
    const opts = options(fixture.root, statusUpdates, [])
    opts.abortSignal = controller.signal

    try {
      const run = runCodexJob(turnStart(), opts)
      await waitForFile(join(codexHomeFor(fixture.root), 'initialize-started.txt'))
      controller.abort(new Error('operator stopped during initialization'))
      await run

      expect(statusUpdates.map(update => update.status)).toEqual(['stopped'])
      expect(parsedJSON(statusUpdates[0]?.metadataJson)?.stop_reason).toBe('operator stopped during initialization')
      expect(existsSync(join(codexHomeFor(fixture.root), 'turn-count.txt'))).toBe(false)
    } finally {
      fixture.cleanup()
    }
  })
})

function options(
  root: string,
  statusUpdates: RecordedStatusUpdate[],
  turnUpserts: RecordedTurnUpsert[],
  jobOverride?: () => BackgroundAgentJobResponse,
  onStatusUpdate?: (update: RecordedStatusUpdate) => void,
  onRPC?: (method: unknown) => void,
  contextSkills: RuntimeSkillSummary[] = [],
  overlayText?: () => string,
  storedTurnItems: Array<{ position: number; itemKey: string; item: Record<string, unknown> }> = []
): CodexJobOptions {
  const job = response(contextSkills)
  const currentJob = () => jobOverride?.() ?? job
  const agentHomeRoot = join(root, 'workspace')
  const agentHome = agentHomeRoot
  const builtinSkillsRoot = join(root, 'builtin-skills')
  mkdirSync(join(builtinSkillsRoot, 'agent-plugins'), { recursive: true })
  const browserRuntime = new BrowserRuntime({
    runtimeRoot: join(root, 'browser-runtime'),
    socketPath: join(root, 'browser-socket', 'browser.sock'),
    daemonEntry: '/bin/true',
    runnerPath: '/bin/true',
    localChromiumExecutable: '/bin/true'
  })

  return {
    agentHome,
    workspaceRoot: join(agentHome, 'jobs', jobID),
    drive: new FakeDrive(agentHome).drive(),
    builtinSkillsRoot,
    agentInstalledSkillsRoot: join(agentHome, 'installed-skills'),
    browserRuntime,
    requestAIGatewayAPIKey: async () =>
      create(AIGatewayAPIKeyResponseSchema, {
        apiKey: 'unused',
        tokenType: 'Bearer',
        expiresAt: BigInt(Math.floor(Date.now() / 1000) + 3_600),
        expiresIn: 3_600n,
        scope: 'ai_gateway',
        baseUrl: 'http://unused.test/v1'
      }),
    rpc: (async (method: unknown, payload: unknown) => {
      onRPC?.(method)
      switch (method) {
        case 'worker_env.resolve':
          return create(WorkerEnvResolveResponseSchema, {
            vars: {
              SAFE_VALUE: 'kept',
              BROWSER_BACKEND_JSON: JSON.stringify({
                kind: 'local_chromium',
                executable: '/bin/true',
                args: ['--from-final-material']
              })
            }
          })
        case 'background_agent_job.get': {
          const request = payload as { resultOffset?: string }
          if (request.resultOffset !== undefined) {
            const output = Buffer.from(currentJob().resultOutputText)
            const offset = Number(request.resultOffset)
            let end = Math.min(offset + 16384, output.length)
            while (end < output.length && (output[end]! & 0xc0) === 0x80) end--
            return create(BackgroundAgentJobResponseSchema, {
              task: 'Source task',
              resultOutputText: output.subarray(offset, end).toString('utf8'),
              resultOutputTotalBytes: String(output.length)
            })
          }
          return currentJob()
        }
        case 'background_agent_job.turn_items.list':
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
        case 'background_agent_job.turn.upsert': {
          const request = payload as RecordedTurnUpsert
          turnUpserts.push(request)
          return turnUpsertResponse(request)
        }
        case 'background_agent_job.status.update': {
          const request = payload as RecordedStatusUpdate
          statusUpdates.push(request)
          onStatusUpdate?.(request)
          return create(BackgroundAgentJobResponseSchema, {
            ...currentJob(),
            status: request.status ?? '',
            runtimeThreadId: request.runtimeThreadId ?? ''
          })
        }
        case 'tools.read': {
          const args = jsonObjectFromBytes((payload as { argumentsJson: Uint8Array }).argumentsJson, 'read args')!
          const name = args.name as string
          const filePath = (args.filePath as string) ?? 'SKILL.md'
          const content = readFileSync(join(builtinSkillsRoot, name, filePath), 'utf8')
          return {
            bodyJson: jsonBytes({ output: `${content}\n${overlayText?.() ?? ''}`, details: { name, path: filePath } })
          }
        }
        default:
          throw new Error(`unexpected RPC method: ${String(method)}`)
      }
    }) as RPCRequester
  }
}

function response(skills: RuntimeSkillSummary[] = []): BackgroundAgentJobResponse {
  return create(BackgroundAgentJobResponseSchema, {
    agentUid: 'agent-1',
    status: 'queued',
    task: 'Write and verify the launch brief.',
    attempts: 1,
    workspaceTemplateId: '',
    workspaceOwnerJobId: jobID,
    metadataJson: jsonBytes({}),
    runtimeProjectionJson: jsonBytes({
      version: 1,
      model_ref: turnStart().model_ref,
      runtime_policy: {},
      skills: skills.map(skill => ({
        id: skill.agentPluginId ? `${skill.agentPluginId}:${skill.skillName}` : skill.skillName,
        name: skill.skillName,
        ...(skill.agentPluginId ? { agent_plugin_id: skill.agentPluginId } : {})
      })),
      agent_plugins: [],
      native_mcp_servers: [],
      worker_env: {
        names: ['BROWSER_BACKEND_JSON', 'SAFE_VALUE'],
        plain_values: {
          BROWSER_BACKEND_JSON: JSON.stringify({
            kind: 'local_chromium',
            executable: '/bin/true',
            args: ['--from-final-material']
          }),
          SAFE_VALUE: 'kept'
        }
      },
      browser: { mode: 'persistent' }
    })
  })
}

function turnStart(skills: RuntimeSkillSummary[] = []): TurnStart {
  return {
    mode: 'start',
    agent_context: create(AgentConversationContextResponseSchema, {
      soul: 'SOUL',
      mission: 'MISSION',
      design: '',
      confidentialityPolicy: '',
      conversation: { driveDirectory: 'chats/mock:dm:alice' },
      skills,
      skillsPrompt: fakeSkillsPrompt(skills)
    }),
    fetch_runtime_config: { ssrfFilter: true },
    turn: {
      session: { session_id: `job:${jobID}` },
      job_id: Number(jobID),
      attempt: 1,
      signal_id: '00000000-0000-0000-0000-000000000001'
    },
    signal: {
      signal_id: '00000000-0000-0000-0000-000000000001',
      type: 'background_agent_job.dispatch',
      payload_json: { data: { job_id: Number(jobID), owner_session_id: 'parent-session', attempts: 1 } }
    },
    model_ref: {
      provider_id: 'openrouter',
      provider_kind: 'openrouter',
      model: 'openai/gpt-5.6-sol',
      provider_options: { reasoningEffort: 'xhigh' },
      supports_parallel_tool_calls: true
    },
    request_context: {}
  }
}

function messageTurnStart(): TurnStart {
  const base = turnStart()
  const signalID = '00000000-0000-0000-0000-000000000002'

  return {
    mode: 'start',
    fetch_runtime_config: { ssrfFilter: true },
    turn: { ...base.turn, signal_id: signalID },
    signal: {
      signal_id: signalID,
      type: 'command.steer',
      payload_json: { data: { command: { argsText: 'The audience is operators.' } } }
    },
    model_ref: base.model_ref,
    agent_context: base.agent_context,
    request_context: base.request_context
  }
}

function steerUpdate() {
  return {
    turn: turnStart().turn,
    correlationID: 'steer-correlation-1',
    signal: {
      signal_id: '00000000-0000-0000-0000-000000000002',
      type: 'command.steer',
      payload_json: { data: { command: { argsText: 'Use the latest operator guidance.' } } }
    }
  }
}

function turnUpsertResponse(request: RecordedTurnUpsert) {
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
      trajectoryJson: request.trajectoryJson,
      progressJson: request.progressJson,
      usageJson: request.usageJson,
      errorJson: request.errorJson,
      startedAt: request.startedAt,
      completedAt: request.completedAt ?? ''
    }
  })
}

function prepareFixture(firstResponse: string, behavior: FakeCodexBehavior = {}): { root: string; cleanup(): void } {
  const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-runner-'))
  mkdirAgentSync(root, 0o700)
  const fakeCodex = join(root, 'fake-codex')
  const fakeFlock = join(root, 'fake-flock')
  const previousFlockBinary = process.env.ANKOLE_FLOCK_BINARY
  const previousStateRoot = process.env.CODEX_SQLITE_HOME
  mkdirAgentSync(jobProjectFor(root))
  writeFakeFlock(fakeFlock)
  writeFakeCodex(fakeCodex, firstResponse, behavior)
  process.env.ANKOLE_CODEX_BINARY = fakeCodex
  process.env.ANKOLE_FLOCK_BINARY = fakeFlock
  process.env.CODEX_SQLITE_HOME = join(root, 'codex-sqlite')
  return {
    root,
    cleanup: () => {
      if (previousFlockBinary === undefined) delete process.env.ANKOLE_FLOCK_BINARY
      else process.env.ANKOLE_FLOCK_BINARY = previousFlockBinary
      if (previousStateRoot === undefined) delete process.env.CODEX_SQLITE_HOME
      else process.env.CODEX_SQLITE_HOME = previousStateRoot
      rmSync(root, { recursive: true, force: true })
    }
  }
}

function writeFakeFlock(path: string): void {
  writeFileSync(path, '#!/bin/sh\nset -eu\nshift 5\nexec "$@"\n')
  chmodSync(path, 0o755)
}

function writeFakeCodex(path: string, firstResponse: string, behavior: FakeCodexBehavior): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
if (process.argv.includes('--version')) {
  console.log('codex-cli 0.163.0')
  process.exit(0)
}
let buffer = ''
let turnCount = 0
let threadCwd = ''
const firstResponse = ${JSON.stringify(firstResponse)}
const resumeError = ${JSON.stringify(behavior.resumeError)}
const turnError = ${JSON.stringify(behavior.turnError)}
const exitOnThreadStart = ${JSON.stringify(behavior.exitOnThreadStart)}
const artifactPath = ${JSON.stringify(behavior.artifactPath)}
const diffPathCount = ${JSON.stringify(behavior.diffPathCount)}
const usageBurstThreadID = ${JSON.stringify(behavior.usageBurstThreadID)}
const multiAgentChildDelayMs = ${JSON.stringify(behavior.multiAgentChildDelayMs)}
const initializeDelayMs = ${JSON.stringify(behavior.initializeDelayMs)}
const dynamicToolCall = ${JSON.stringify(behavior.dynamicToolCall)}
const dynamicToolCompletionDelayMs = ${JSON.stringify(behavior.dynamicToolCompletionDelayMs ?? 0)}
const successfulSteer = ${JSON.stringify(behavior.successfulSteer)}
const loseThreadAfterSteer = ${JSON.stringify(behavior.loseThreadAfterSteer)}
const steerCompletionRace = ${JSON.stringify(behavior.steerCompletionRace)}
const interruptCompletionRace = ${JSON.stringify(behavior.interruptCompletionRace)}
const mcpStartupFailure = ${JSON.stringify(behavior.mcpStartupFailure)}
const cleanupError = ${JSON.stringify(behavior.cleanupError)}
const suppressTurnNotifications = ${JSON.stringify(behavior.suppressTurnNotifications)}
const responsePhase = ${JSON.stringify(behavior.responsePhase)}
const workAfterResponse = ${JSON.stringify(behavior.workAfterResponse)}
const compactionAfterResponse = ${JSON.stringify(behavior.compactionAfterResponse)}
const repeatIncompleteResponse = ${JSON.stringify(behavior.repeatIncompleteResponse)}
const compactFirstTurn = ${JSON.stringify(behavior.compactFirstTurn)}
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function handle(message) {
  if (message.id === 101 && Object.hasOwn(message, 'result')) {
    writeFileSync(process.env.CODEX_HOME + '/tool-response.json', JSON.stringify(message))
    setTimeout(() => {
      write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', id: 'message-tool', text: firstResponse } } })
      write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } })
    }, dynamicToolCompletionDelayMs)
    return
  }
  if (message.method === 'initialize') {
    writeFileSync(process.env.CODEX_HOME + '/initialize-started.txt', 'started')
    const response = { id: message.id, result: { userAgent: 'codex-cli 0.163.0' } }
    if (initializeDelayMs) return setTimeout(() => write(response), initializeDelayMs)
    return write(response)
  }
  if (message.method === 'initialized') return
  if (message.method === 'thread/start') {
    if (exitOnThreadStart) return process.exit(51)
    threadCwd = message.params.cwd
    writeFileSync(process.env.CODEX_HOME + '/thread-start.json', JSON.stringify(message.params))
    const threadEnv = message.params.config?.shell_environment_policy?.set ?? {}
    writeFileSync(message.params.cwd + '/browser-env.json', JSON.stringify({
      ANKOLE_BROWSER_SOCKET: threadEnv.ANKOLE_BROWSER_SOCKET,
      ANKOLE_BROWSER_ROUTE: threadEnv.ANKOLE_BROWSER_ROUTE,
      ANKOLE_BROWSER_SESSION: threadEnv.ANKOLE_BROWSER_SESSION,
      ANKOLE_BROWSER_MATERIAL: threadEnv.ANKOLE_BROWSER_MATERIAL,
      ANKOLE_BROWSER_ARTIFACT_ROOT: threadEnv.ANKOLE_BROWSER_ARTIFACT_ROOT,
      BROWSER_BACKEND_JSON: threadEnv.BROWSER_BACKEND_JSON,
      SAFE_VALUE: threadEnv.SAFE_VALUE,
      MCPORTER_CONFIG: threadEnv.MCPORTER_CONFIG,
      MCPORTER_CONFIG_CONTENT: threadEnv.MCPORTER_CONFIG ? readFileSync(threadEnv.MCPORTER_CONFIG, 'utf8') : undefined
    }))
    write({ id: message.id, result: { thread: { id: 'thread-1' } } })
    if (mcpStartupFailure) {
      write({ method: 'mcpServer/startupStatus/updated', params: { threadId: 'thread-1', name: mcpStartupFailure.name, status: 'starting', error: null, failureReason: null } })
      write({ method: 'mcpServer/startupStatus/updated', params: { threadId: 'thread-1', name: mcpStartupFailure.name, status: 'failed', error: mcpStartupFailure.error, failureReason: null } })
    }
    return
  }
  if (message.method === 'thread/resume') {
    writeFileSync(process.env.CODEX_HOME + '/thread-resume.json', JSON.stringify(message.params))
    if (resumeError) {
      return write({
        id: message.id,
        error: typeof resumeError === 'string' ? { code: -32000, message: resumeError } : resumeError
      })
    }
    threadCwd = message.params.cwd
    return write({ id: message.id, result: { thread: { id: message.params.threadId } } })
  }
  if (message.method === 'thread/inject_items') {
    writeFileSync(process.env.CODEX_HOME + '/inject-items.json', JSON.stringify(message.params))
    return write({ id: message.id, result: {} })
  }
  if (message.method === 'turn/start') {
    turnCount += 1
    writeFileSync(process.env.CODEX_HOME + '/turn-count.txt', String(turnCount))
    const input = Array.isArray(message.params.input) ? message.params.input[0]?.text : ''
    if (turnCount === 1) writeFileSync(process.env.CODEX_HOME + '/turn-input.txt', input || '')
    const turnID = 'turn-' + turnCount
    write({ id: message.id, result: { turn: { id: turnID, status: 'in_progress' } } })
    if (suppressTurnNotifications) return
    if (compactFirstTurn) {
      write({ method: 'turn/started', params: { threadId: 'thread-1', turn: { id: turnID, status: 'inProgress', items: [] } } })
      setTimeout(() => {
        if (turnCount === 1) {
          write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: turnID, status: 'failed', error: { message: 'context window exceeded', codexErrorInfo: 'contextWindowExceeded' } } } })
          return
        }
        write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'contextCompaction', id: 'auto-compaction-' + turnCount } } })
        write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'agentMessage', id: 'message-' + turnCount, text: 'final response after retry' } } })
        write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: turnID, status: 'completed' } } })
      }, 10)
      return
    }
    if (turnError) {
      setTimeout(() => {
        write({
          method: 'turn/completed',
          params: {
            threadId: 'thread-1',
            turn: {
              id: turnID,
              status: 'failed',
              error: typeof turnError === 'string' ? { message: turnError } : turnError
            }
          }
        })
      }, 10)
      return
    }
    if (dynamicToolCall) {
      const call = dynamicToolCall === true ? { tool: 'unavailable_tool', arguments: {} } : dynamicToolCall
      write({ id: 101, method: 'item/tool/call', params: { tool: call.tool, callId: 'call-101', threadId: 'thread-1', turnId: turnID, arguments: call.arguments } })
      return
    }
    if (steerCompletionRace || (successfulSteer && (!loseThreadAfterSteer || turnCount === 1))) return
    if (interruptCompletionRace) return
    if (multiAgentChildDelayMs !== undefined) {
      write({ method: 'turn/started', params: { threadId: 'thread-1', turn: { id: turnID, status: 'inProgress', items: [] } } })
      write({ method: 'rawResponseItem/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'function_call', name: 'spawn_agent', namespace: 'collaboration', arguments: JSON.stringify({ task_name: 'child', message: 'Complete the child task.', fork_turns: 'none' }), call_id: 'spawn-child' } } })
      write({ method: 'turn/started', params: { threadId: 'child-thread', turn: { id: 'child-turn', status: 'inProgress', items: [] } } })
      write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'subAgentActivity', id: 'spawn-child', kind: 'started', agentThreadId: 'child-thread', agentPath: '/root/child' } } })
      write({ method: 'rawResponseItem/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'function_call_output', call_id: 'spawn-child', output: JSON.stringify({ task_name: '/root/child' }) } } })
      setTimeout(() => {
        write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'agentMessage', id: 'message-' + turnCount, text: firstResponse } } })
        write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: turnID, status: 'completed' } } })
      }, 10)
      setTimeout(() => {
        write({ method: 'item/started', params: { threadId: 'child-thread', turnId: 'child-turn', item: { type: 'agentMessage', id: 'child-message', text: '' } } })
        write({ method: 'item/completed', params: { threadId: 'child-thread', turnId: 'child-turn', item: { type: 'agentMessage', id: 'child-message', text: 'child result' } } })
        write({ method: 'turn/completed', params: { threadId: 'child-thread', turn: { id: 'child-turn', status: 'completed' } } })
      }, multiAgentChildDelayMs)
      return
    }
    if (usageBurstThreadID) {
      for (let index = 1; index <= 8; index += 1) {
        const totalTokens = index * 100
        write({
          method: 'thread/tokenUsage/updated',
          params: {
            threadId: usageBurstThreadID,
            tokenUsage: {
              total: {
                totalTokens,
                inputTokens: totalTokens - 10,
                cachedInputTokens: 0,
                outputTokens: 10,
                reasoningOutputTokens: 0
              },
              last: {
                totalTokens: 100,
                inputTokens: 90,
                cachedInputTokens: 0,
                outputTokens: 10,
                reasoningOutputTokens: 0
              },
              modelContextWindow: 1000
            }
          }
        })
      }
    }
    const useFirstResponse = turnCount === 1 || repeatIncompleteResponse
    const text = useFirstResponse ? firstResponse : 'final response after retry'
    const phase = useFirstResponse ? responsePhase : 'final_answer'
    write({ method: 'turn/started', params: { threadId: 'thread-1', turn: { id: turnID, status: 'inProgress', items: [] } } })
    setTimeout(() => {
      if (artifactPath) {
        const artifactTarget = artifactPath.startsWith('/') ? artifactPath : threadCwd + '/' + artifactPath
        writeFileSync(artifactTarget, 'artifact')
        // diffPathCount 0 models a shell-written file that no Codex tool reported.
        if (diffPathCount !== 0) write({ method: 'turn/diff/updated', params: { threadId: 'thread-1', turnId: turnID, diff: '--- /dev/null\\n+++ b/' + artifactPath + '\\n' } })
      }
      if (diffPathCount) {
        let diff = ''
        for (let index = 0; index < diffPathCount; index += 1) {
          diff += '--- /dev/null\\n+++ b/report/artifact-' + index + '.pdf\\n'
        }
        write({ method: 'turn/diff/updated', params: { threadId: 'thread-1', turnId: turnID, diff } })
      }
      write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'agentMessage', id: 'message-' + turnCount, text, phase } } })
      if (useFirstResponse && workAfterResponse) {
        const item = { type: 'commandExecution', id: 'command-' + turnCount, command: 'cat playbook.md', cwd: threadCwd, status: 'inProgress', commandActions: [] }
        write({ method: 'item/started', params: { threadId: 'thread-1', turnId: turnID, item } })
        write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item: { ...item, status: 'completed', aggregatedOutput: 'playbook', exitCode: 0, durationMs: 1 } } })
      }
      if (useFirstResponse && compactionAfterResponse) {
        const item = { type: 'contextCompaction', id: 'compaction-after-' + turnCount }
        write({ method: 'item/started', params: { threadId: 'thread-1', turnId: turnID, item } })
        write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item } })
      }
      write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: turnID, status: 'completed' } } })
    }, 10)
    return
  }
  if (message.method === 'turn/steer' && steerCompletionRace) {
    write({ id: message.id, error: { code: -32000, message: 'no active turn to steer' } })
    setTimeout(() => {
      write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', id: 'message-steer-race', text: firstResponse } } })
      write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } })
    }, 5)
    return
  }
  if (message.method === 'turn/steer' && successfulSteer) {
    const input = Array.isArray(message.params.input) ? message.params.input[0]?.text : ''
    writeFileSync(process.env.CODEX_HOME + '/steer-input.txt', input || '')
    write({ id: message.id, result: { turn: { id: 'turn-1', status: 'in_progress' } } })
    setTimeout(() => {
      if (loseThreadAfterSteer) {
        return write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'failed', error: { message: 'No rollout found for thread' } } } })
      }
      write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', id: 'message-steered', text: firstResponse } } })
      write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } })
    }, 10)
    return
  }
  if (message.method === 'turn/interrupt' && interruptCompletionRace) {
    write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-1', item: { type: 'agentMessage', id: 'message-stop-race', text: firstResponse } } })
    write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } })
    setTimeout(() => write({ id: message.id, error: { code: -32000, message: 'turn already completed' } }), 5)
    return
  }
  if (message.method === 'turn/interrupt') return write({ id: message.id, result: {} })
  if (message.method === 'thread/compact/start') {
    writeFileSync(process.env.CODEX_HOME + '/compact-start.json', JSON.stringify(message.params))
    write({ id: message.id, result: {} })
    setTimeout(() => {
      write({ method: 'turn/started', params: { threadId: 'thread-1', turn: { id: 'turn-compact', status: 'inProgress', items: [] } } })
      write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: 'turn-compact', item: { type: 'contextCompaction', id: 'compaction-1' } } })
      write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-compact', status: 'completed' } } })
    }, 10)
    return
  }
  if (message.method === 'thread/unsubscribe' && cleanupError) {
    return write({ id: message.id, error: { code: -32000, message: 'cleanup failed after completion' } })
  }
  if (message.id !== undefined) write({ id: message.id, result: {} })
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
`,
    { mode: 0o755 }
  )
  chmodSync(path, 0o755)
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) delete process.env[key]
  else process.env[key] = value
}

async function waitForFile(path: string): Promise<void> {
  const deadline = Date.now() + 2_000
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${path}`)
    await Bun.sleep(5)
  }
}

function jobProjectFor(root: string, workspaceOwnerJobID = jobID): string {
  return join(root, 'workspace', 'jobs', workspaceOwnerJobID)
}

// Thread files stay in the persistent Agent Home; SQLite uses the cache.
function codexHomeFor(root: string): string {
  return join(root, 'workspace', '.codex')
}

// The control plane selects the Job's Skills and renders their index. This
// fake lists the Skills the Job runtime can load and the prompt shows, in the
// same line shape.
function fakeSkillsPrompt(skills: RuntimeSkillSummary[]): string {
  const lines = skills
    .filter(skill => {
      const metadata = parsedJSON(skill.metadataJson)
      return metadata?.['ankole-runtime'] !== 'main' && metadata?.['brain_recall_only'] !== true
    })
    .map(skill => `    - ${skill.skillName}: ${skill.description}`)
  return lines.length === 0
    ? ''
    : ['## Skills', '<available_skills>', '  general:', ...lines, '</available_skills>'].join('\n')
}
