import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { runCodexJob } from '../src/core/codex-runner'
import { create } from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import {
  AgentConversationContextResponseSchema,
  AgentPluginListResponseSchema,
  AIGatewayAPIKeyResponseSchema,
  AppConfigureResolveResponseSchema,
  BackgroundAgentJobResponseSchema,
  BackgroundAgentJobTurnUpsertResponseSchema,
  WorkerEnvResolveResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  rpcMethods,
  type BackgroundAgentJobResponse,
  type RPCRequester,
  type RPCRequestInit
} from '../src/lanes/rpc_lane'

type RecordedStatusUpdate = RPCRequestInit<'background_agent_job.status.update'> & {
  metadataJson?: Uint8Array
  resultJson?: Uint8Array
}
type RecordedTurnUpsert = RPCRequestInit<'background_agent_job.turn.upsert'> & {
  trajectoryJson?: Uint8Array
  progressJson?: Uint8Array
  usageJson?: Uint8Array
  errorJson?: Uint8Array
}

function parsedJSON(bytes: Uint8Array | undefined): JSONObject | undefined {
  return bytes ? jsonObjectFromBytes(bytes, 'test fixture json') : undefined
}
import type { TurnStart } from '../src/lanes/actor_lane'
import type { CodexJobOptions } from '../src/core/turns/turn_options'
import { BrowserRuntime } from '../src/browser-runtime'

const jobID = '019f0000-0000-7000-8000-000000000001'
const previousCodexBinary = process.env.ANKOLE_CODEX_BINARY
const previousBwrap = process.env.ANKOLE_BWRAP_PATH

afterEach(() => {
  restoreEnv('ANKOLE_CODEX_BINARY', previousCodexBinary)
  restoreEnv('ANKOLE_BWRAP_PATH', previousBwrap)
})

describe('@ankole/agent-computer Codex job runner', () => {
  it('commits the ordinary Codex final response as the generic Job result', async () => {
    const fixture = prepareFixture('done')
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []

    try {
      const result = await runCodexJob(turnStart(), options(fixture.root, statusUpdates, turnUpserts))

      expect(result).toEqual({ kind: 'noop_completed', reason: 'background_agent_job_committed' })
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).toMatchObject({
        codex_user_agent: 'codex-cli 0.144.5',
        job_project_cwd: '/workspace',
        workspace_mounts: [{ mount_id: 'workspace', path: '/workspace/workspaces/workspace', access: 'read_write' }],
        projected_tool_names: [
          'web_search',
          'web_fetch',
          'memory_search',
          'memory_open',
          'memory_update',
          'memory_browse',
          'memory_health_check',
          'request_parent_input'
        ]
      })
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).not.toHaveProperty('agent_plugins')
      expect(parsedJSON(statusUpdates[0]?.metadataJson)).not.toHaveProperty('input_snapshots_materialized')
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)).toMatchObject({
        output_text: 'done',
        stop_reason: 'completed',
        attempt: 1,
        runtime_thread_id: 'thread-1',
        codex_turn_status: 'completed'
      })
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)).not.toHaveProperty('verification')
      expect(parsedJSON(statusUpdates.at(-1)?.resultJson)).not.toHaveProperty('artifacts')
      expect(turnUpserts.some(update => update.status === 'completed')).toBe(true)
      expect(readFileSync(join(jobProjectFor(fixture.root), 'turn-input.txt'), 'utf8')).toBe(response().task)
      const browserEnv = JSON.parse(
        readFileSync(join(jobProjectFor(fixture.root), 'browser-env.json'), 'utf8')
      ) as Record<string, string>
      expect(browserEnv).toMatchObject({
        ANKOLE_BROWSER_SOCKET: '/run/ankole-browser/socket/browser.sock',
        ANKOLE_BROWSER_SESSION: 'default',
        ANKOLE_BROWSER_MATERIAL: '/run/ankole-browser/material/session.json',
        ANKOLE_BROWSER_ARTIFACT_ROOT: '/workspace/browser',
        SAFE_VALUE: 'kept'
      })
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
      expect(readdirSync(join(fixture.root, 'sessions', '_browser', 'materials'))).toEqual([])
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
      expect(readFileSync(join(jobProjectFor(fixture.root), 'turn-count.txt'), 'utf8')).toBe('2')
    } finally {
      fixture.cleanup()
    }
  })

  it('fails preparation when a saved Agent Plugin ID is absent from the current enabled catalog', async () => {
    const fixture = prepareFixture('unused')
    const statusUpdates: RecordedStatusUpdate[] = []
    const turnUpserts: RecordedTurnUpsert[] = []
    const opts = options(fixture.root, statusUpdates, turnUpserts, () =>
      create(BackgroundAgentJobResponseSchema, { ...response(), agentPluginIds: ['office'] })
    )

    try {
      await expect(runCodexJob(turnStart(), opts)).rejects.toThrow('Selected Agent Plugin is unavailable: office')
      expect(statusUpdates).toEqual([])
      expect(turnUpserts).toEqual([])
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
})

function options(
  root: string,
  statusUpdates: RecordedStatusUpdate[],
  turnUpserts: RecordedTurnUpsert[],
  jobOverride?: () => BackgroundAgentJobResponse
): CodexJobOptions {
  const job = response()
  const currentJob = () => jobOverride?.() ?? job
  const sessionsRoot = join(root, 'sessions')
  const userFilesRoot = join(root, 'user-files')
  const browserRuntime = new BrowserRuntime({
    workspaceSessionsRoot: sessionsRoot,
    socketPath: join(root, 'browser-socket', 'browser.sock'),
    localChromiumExecutable: '/bin/true'
  })

  return {
    workspaceRoot: join(sessionsRoot, 'agent-1', `job:${jobID}`),
    workspaceSessionsRoot: sessionsRoot,
    sharedFsRoot: join(root, 'shared'),
    userFilesRoot,
    builtinSkillsRoot: join(root, 'builtin-skills'),
    agentInstalledSkillsRoot: join(root, 'installed-skills'),
    browserRuntime,
    requestAIGatewayAPIKey: async agentUid =>
      create(AIGatewayAPIKeyResponseSchema, {
        agentUid,
        apiKey: 'unused',
        tokenType: 'Bearer',
        expiresAt: BigInt(Math.floor(Date.now() / 1000) + 3_600),
        expiresIn: 3_600n,
        scope: 'ai_gateway',
        baseUrl: 'http://unused.test/v1'
      }),
    rpc: (async (method: unknown, payload: unknown) => {
      switch (method) {
        case rpcMethods.workerEnvResolve:
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
        case rpcMethods.appConfigureResolve:
          return create(AppConfigureResolveResponseSchema, { values: {} })
        case rpcMethods.backgroundAgentJobGet:
          return currentJob()
        case rpcMethods.backgroundAgentJobTurnUpsert: {
          const request = payload as RecordedTurnUpsert
          turnUpserts.push(request)
          return turnUpsertResponse(request)
        }
        case rpcMethods.backgroundAgentJobStatusUpdate: {
          const request = payload as RecordedStatusUpdate
          statusUpdates.push(request)
          return create(BackgroundAgentJobResponseSchema, {
            ...currentJob(),
            status: request.status ?? '',
            runtimeThreadId: request.runtimeThreadId ?? ''
          })
        }
        case rpcMethods.agentConversationContextResolve:
          return create(AgentConversationContextResponseSchema, {
            soul: 'SOUL',
            mission: 'MISSION',
            skills: []
          })
        case rpcMethods.agentPluginList:
          return create(AgentPluginListResponseSchema, { agentPlugins: [] })
        case rpcMethods.codexAccountResolve:
        case rpcMethods.codexAccountAuthUpdate:
          throw new Error('official Codex account is not used by this fixture')
        default:
          throw new Error(`unexpected RPC method: ${String(method)}`)
      }
    }) as RPCRequester
  }
}

function response(): BackgroundAgentJobResponse {
  return create(BackgroundAgentJobResponseSchema, {
    jobId: jobID,
    agentUid: 'agent-1',
    ownerSessionId: 'parent-session',
    status: 'queued',
    codexAccountId: 'aigateway',
    title: 'Prepare launch brief',
    task: 'Write and verify the launch brief.',
    background: 'The launch brief is for operators.',
    notes: 'Keep the handoff concise.',
    replyRouteJson: jsonBytes({ binding_name: 'lark', signal_channel_id: 'chat-1' }),
    attempts: 1,
    agentPluginIds: [],
    skillNames: [],
    workspaceMounts: [
      {
        id: 'workspace',
        source: `/workspace/user-files/background-agent-jobs/${jobID}/workspace`,
        access: 'read_write'
      }
    ]
  })
}

function turnStart(): TurnStart {
  return {
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
      payload_json: { data: { job_id: jobID, owner_session_id: 'parent-session', attempts: 1 } }
    },
    request_context: {
      turn_mode: 'background_agent_job',
      job_id: jobID,
      owner_session_id: 'parent-session',
      attempts: 1
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

function prepareFixture(
  firstResponse: string,
  behavior: { resumeError?: string | Record<string, unknown> } = {}
): { root: string; cleanup(): void } {
  const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-runner-'))
  const fakeCodex = join(root, 'fake-codex')
  const fakeBwrap = join(root, 'fake-bwrap')
  mkdirSync(join(root, 'sessions'), { recursive: true })
  mkdirSync(jobWorkspaceFor(root), { recursive: true })
  writeFakeBwrap(fakeBwrap)
  writeFakeCodex(fakeCodex, firstResponse, behavior)
  process.env.ANKOLE_CODEX_BINARY = fakeCodex
  process.env.ANKOLE_BWRAP_PATH = fakeBwrap
  return { root, cleanup: () => rmSync(root, { recursive: true, force: true }) }
}

function writeFakeCodex(
  path: string,
  firstResponse: string,
  behavior: { resumeError?: string | Record<string, unknown> }
): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
if (process.argv.includes('--version')) {
  console.log('codex-cli 0.144.5')
  process.exit(0)
}
writeFileSync('browser-env.json', JSON.stringify({
  ANKOLE_BROWSER_SOCKET: process.env.ANKOLE_BROWSER_SOCKET,
  ANKOLE_BROWSER_ROUTE: process.env.ANKOLE_BROWSER_ROUTE,
  ANKOLE_BROWSER_SESSION: process.env.ANKOLE_BROWSER_SESSION,
  ANKOLE_BROWSER_MATERIAL: process.env.ANKOLE_BROWSER_MATERIAL,
  ANKOLE_BROWSER_ARTIFACT_ROOT: process.env.ANKOLE_BROWSER_ARTIFACT_ROOT,
  BROWSER_BACKEND_JSON: process.env.BROWSER_BACKEND_JSON,
  SAFE_VALUE: process.env.SAFE_VALUE
}))
let buffer = ''
let turnCount = 0
const firstResponse = ${JSON.stringify(firstResponse)}
const resumeError = ${JSON.stringify(behavior.resumeError)}
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function handle(message) {
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.5' } })
  if (message.method === 'initialized') return
  if (message.method === 'skills/list') {
    return write({ id: message.id, result: { data: [{ cwd: message.params.cwds[0], skills: [], errors: [] }] } })
  }
  if (message.method === 'thread/start') {
    return write({ id: message.id, result: { thread: { id: 'thread-1' } } })
  }
  if (message.method === 'thread/resume') {
    if (resumeError) {
      return write({
        id: message.id,
        error: typeof resumeError === 'string' ? { code: -32000, message: resumeError } : resumeError
      })
    }
    return write({ id: message.id, result: { thread: { id: message.params.threadId } } })
  }
  if (message.method === 'turn/start') {
    turnCount += 1
    writeFileSync('turn-count.txt', String(turnCount))
    const input = Array.isArray(message.params.input) ? message.params.input[0]?.text : ''
    if (turnCount === 1) writeFileSync('turn-input.txt', input || '')
    const turnID = 'turn-' + turnCount
    write({ id: message.id, result: { turn: { id: turnID, status: 'in_progress' } } })
    const text = turnCount === 1 ? firstResponse : 'final response after retry'
    setTimeout(() => {
      write({ method: 'item/completed', params: { threadId: 'thread-1', turnId: turnID, item: { type: 'agentMessage', id: 'message-' + turnCount, text } } })
      write({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: turnID, status: 'completed' } } })
    }, 10)
    return
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

function writeFakeBwrap(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bash
set -euo pipefail
workspace_src=""
chdir=""
translate() {
  if [[ -n "$workspace_src" && "$1" == "/workspace" ]]; then printf "%s" "$workspace_src"
  elif [[ -n "$workspace_src" && "$1" == /workspace/* ]]; then printf "%s/%s" "$workspace_src" "\${1#/workspace/}"
  else printf "%s" "$1"; fi
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unshare-all|--share-net|--die-with-parent|--new-session|--clearenv) shift ;;
    --proc|--dev|--tmpfs|--dir) shift 2 ;;
    --bind|--ro-bind)
      if [[ "\${3:-}" == "/workspace" ]]; then workspace_src="$2"; fi
      shift 3
      ;;
    --chdir) chdir="$2"; shift 2 ;;
    --setenv) export "$2=$3"; shift 3 ;;
    --) shift; break ;;
    --*) echo "unsupported option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [[ "\${1:-}" == "/bin/sh" && "\${2:-}" == "-lc" && "\${3:-}" == "test -r /proc/self/status && test -w /tmp" ]]; then exit 0; fi
if [[ -n "$chdir" ]]; then cd "$(translate "$chdir")"; fi
exec "$@"
`,
    { mode: 0o755 }
  )
  chmodSync(path, 0o755)
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) delete process.env[key]
  else process.env[key] = value
}

function jobProjectFor(root: string): string {
  return join(root, 'user-files', 'background-agent-jobs', jobID, 'project')
}

function jobWorkspaceFor(root: string): string {
  return join(root, 'user-files', 'background-agent-jobs', jobID, 'workspace')
}
