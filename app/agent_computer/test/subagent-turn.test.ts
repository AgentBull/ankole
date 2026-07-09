import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { JsonObject } from '@pleisto/active-support'
import { runSubagentTurn } from '../src/core/turns/subagent_turn'
import { CodexConfigOverrideKey } from '../src/tools/codex/config'
import type {
  SubagentDelegationEventAppendRequest,
  SubagentDelegationResponse,
  SubagentDelegationStatusUpdateRequest
} from '../src/lanes/rpc_lane'
import type { TurnStart } from '../src/lanes/actor_lane'

const delegationId = '019f0000-0000-7000-8000-000000000001'
const previousCodexBinary = process.env.ANKOLE_CODEX_BINARY
const previousBwrap = process.env.ANKOLE_BWRAP_PATH

afterEach(() => {
  restoreEnv('ANKOLE_CODEX_BINARY', previousCodexBinary)
  restoreEnv('ANKOLE_BWRAP_PATH', previousBwrap)
})

describe('@ankole/agent-computer subagent turn', () => {
  it('runs one durable Codex turn, batches audit, and commits success before noop', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-turn-'))
    const sessionsRoot = join(root, 'sessions')
    const userFilesRoot = join(root, 'user-files')
    const fakeCodex = join(root, 'fake-codex')
    const fakeBwrap = join(root, 'fake-bwrap')
    mkdirSync(sessionsRoot, { recursive: true })
    mkdirSync(userFilesRoot, { recursive: true })
    writeFakeBwrap(fakeBwrap)
    writeFakeCodex(fakeCodex)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex
    process.env.ANKOLE_BWRAP_PATH = fakeBwrap

    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const activity: string[] = []
    const delegation = response()

    try {
      const result = await runSubagentTurn(turnStart(), {
        workspaceRoot: join(sessionsRoot, 'agent-1', `subagent:${delegationId}`),
        workspaceSessionsRoot: sessionsRoot,
        userFilesRoot,
        requestAIGatewayApiKey: async request => ({
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          api_key: 'unused',
          token_type: 'Bearer',
          expires_at: Math.floor(Date.now() / 1000) + 3600,
          expires_in: 3600,
          scope: 'ai_gateway',
          base_url: 'http://unused.test/v1'
        }),
        requestAppConfigure: async request => ({
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          values: {
            [CodexConfigOverrideKey]: {
              source: 'global',
              value: { mode: 'official_subscription', config_toml: 'model = "test"' }
            }
          }
        }),
        getSubagentDelegation: async () => delegation,
        appendSubagentDelegationEvents: async request => {
          auditBatches.push(request)
          return {
            request_id: request.request_id,
            delegation_id: request.delegation_id,
            events: request.events.map(event => ({ seq: event.seq, event_id: `event-${event.seq}` })),
            last_event_seq: request.events.at(-1)?.seq
          }
        },
        updateSubagentDelegationStatus: async request => {
          statusUpdates.push(request)
          return { ...delegation, status: request.status, runtime_thread_id: request.runtime_thread_id }
        },
        onTurnActivity: description => activity.push(description ?? ''),
        requestAgentConversationContext: async request => ({
          request_id: request.request_id,
          agent_uid: 'agent-1',
          session_id: `subagent:${delegationId}`,
          turn: request.turn,
          agent: { display_name: 'Ankole Agent', role: 'colleague' },
          conversation: {},
          soul: 'SOUL: Be careful and evidence-driven.',
          mission: 'MISSION: Ship reliable work.',
          skills: [],
          memory_notes: [],
          cache_key: 'subagent-context'
        })
      })

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'running', 'succeeded'])
      expect(statusUpdates[0]?.metadata?.codex_home_relative_path).toContain(`.ankole/subagent/${delegationId}`)
      expect(statusUpdates[0]?.metadata).toMatchObject({
        codex_user_agent: 'codex-cli 0.144.0',
        projected_tool_names: ['skill_view'],
        quarantined_tool_names: [],
        projected_skill_count: 0
      })
      expect(statusUpdates[1]).toMatchObject({
        runtime_thread_id: 'thread-2',
        metadata: { runtime_thread_recreated_reason: 'unknown_session' }
      })
      expect(statusUpdates.at(-1)?.result?.output_text).toBe('done')
      expect(statusUpdates.at(-1)?.result?.usage).toMatchObject({ totalTokens: 21, outputTokens: 5 })
      expect(statusUpdates.at(-1)?.result?.files_changed).toEqual(['brief.md', 'removed.md'])
      expect(readFileSync(join(workdirFor(root), 'compact-called.txt'), 'utf8')).toBe('yes')
      expect(readFileSync(join(workdirFor(root), 'turn-start-count.txt'), 'utf8')).toBe('4')
      expect(activity).toContain('codex:agent_delta')
      expect(auditBatches.length).toBeGreaterThan(0)
      expect(auditBatches.every(batch => batch.events.length <= 20)).toBe(true)
      expect(auditBatches.flatMap(batch => batch.events).map(event => event.seq)).toEqual(
        auditBatches.flatMap(batch => batch.events).map((_, index) => index)
      )

      const parentRoot = join(sessionsRoot, 'agent-1', 'parent-session')
      const workdir = workdirFor(root)
      const threadStart = JSON.parse(readFileSync(join(workdir, 'thread-start.json'), 'utf8')) as JsonObject
      expect(String(threadStart.developerInstructions)).toContain('SOUL: Be careful')
      expect(String(threadStart.developerInstructions)).toContain('Background task safety')
      expect(existsSync(join(parentRoot, '.ankole', 'subagent', delegationId, 'home', 'config.toml'))).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 15_000)

  it('ends on requestUserInput and resumes a new turn with journaled answers', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-waiting-'))
    const sessionsRoot = join(root, 'sessions')
    const userFilesRoot = join(root, 'user-files')
    const fakeCodex = join(root, 'fake-codex-waiting')
    const fakeBwrap = join(root, 'fake-bwrap')
    mkdirSync(sessionsRoot, { recursive: true })
    mkdirSync(userFilesRoot, { recursive: true })
    writeFakeBwrap(fakeBwrap)
    writeWaitingFakeCodex(fakeCodex)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex
    process.env.ANKOLE_BWRAP_PATH = fakeBwrap

    const updates: SubagentDelegationStatusUpdateRequest[] = []
    let current = response()
    const options = {
      workspaceRoot: join(sessionsRoot, 'agent-1', `subagent:${delegationId}`),
      workspaceSessionsRoot: sessionsRoot,
      userFilesRoot,
      requestAIGatewayApiKey: async (request: { request_id: string; agent_uid: string }) => ({
        request_id: request.request_id,
        agent_uid: request.agent_uid,
        api_key: 'unused',
        token_type: 'Bearer' as const,
        expires_at: Math.floor(Date.now() / 1000) + 3600,
        expires_in: 3600,
        scope: 'ai_gateway' as const,
        base_url: 'http://127.0.0.1:1/v1'
      }),
      requestAppConfigure: async (request: { request_id: string; agent_uid: string }) => ({
        request_id: request.request_id,
        agent_uid: request.agent_uid,
        values: {
          [CodexConfigOverrideKey]: {
            source: 'global',
            value: { mode: 'official_subscription', config_toml: 'model = "test"' }
          }
        }
      }),
      getSubagentDelegation: async () => current,
      appendSubagentDelegationEvents: async (request: SubagentDelegationEventAppendRequest) => ({
        request_id: request.request_id,
        delegation_id: request.delegation_id,
        events: request.events.map(event => ({ seq: event.seq, event_id: `event-${event.seq}` })),
        last_event_seq: request.events.at(-1)?.seq
      }),
      updateSubagentDelegationStatus: async (request: SubagentDelegationStatusUpdateRequest) => {
        updates.push(request)
        current = {
          ...current,
          status: request.status,
          runtime_thread_id: request.runtime_thread_id,
          metadata: { ...current.metadata, ...request.metadata }
        }
        return current
      },
      requestAgentConversationContext: async (request: { request_id: string; turn: TurnStart['turn'] }) => ({
        request_id: request.request_id,
        agent_uid: 'agent-1',
        session_id: `subagent:${delegationId}`,
        turn: request.turn,
        conversation: {},
        soul: 'SOUL',
        mission: 'MISSION',
        skills: [],
        memory_notes: [],
        cache_key: 'context'
      })
    }

    try {
      const waitingResult = await runSubagentTurn(turnStart(), options)
      expect(waitingResult.kind).toBe('noop_completed')
      const waiting = updates.find(update => update.status === 'waiting_on_user')
      expect(waiting?.metadata?.pending_user_input).toMatchObject({
        questions: [{ id: 'audience', question: 'Who is the audience?' }]
      })
      expect(current.runtime_thread_id).toBe('thread-wait')

      current = { ...current, status: 'running', attempts: 2 }
      const resumed = await runSubagentTurn(steerTurnStart(), options)
      expect(resumed.kind).toBe('noop_completed')
      expect(updates.at(-1)?.status).toBe('succeeded')
      expect(updates.at(-1)?.result?.output_text).toBe('resumed')

      const parentRoot = join(sessionsRoot, 'agent-1', 'parent-session')
      const workdir = join(parentRoot, 'user-files', 'subagent', '019f0000')
      expect(readFileSync(join(workdir, 'resume-input.txt'), 'utf8')).toContain('audience: Operators')
      expect(readFileSync(join(workdir, 'resume-input.txt'), 'utf8')).toContain('Write and verify the launch brief.')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 10_000)

  it('fails the execution attempt when the Codex compaction turn fails', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-compact-failure-'))
    const sessionsRoot = join(root, 'sessions')
    const userFilesRoot = join(root, 'user-files')
    const fakeCodex = join(root, 'fake-codex-compact-failure')
    const fakeBwrap = join(root, 'fake-bwrap')
    mkdirSync(sessionsRoot, { recursive: true })
    mkdirSync(userFilesRoot, { recursive: true })
    writeFakeBwrap(fakeBwrap)
    writeCompactionFailureFakeCodex(fakeCodex)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex
    process.env.ANKOLE_BWRAP_PATH = fakeBwrap
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const delegation = response()

    try {
      await expect(
        runSubagentTurn(turnStart(), {
          workspaceRoot: join(sessionsRoot, 'agent-1', `subagent:${delegationId}`),
          workspaceSessionsRoot: sessionsRoot,
          userFilesRoot,
          requestAIGatewayApiKey: async request => ({
            request_id: request.request_id,
            agent_uid: request.agent_uid,
            api_key: 'unused',
            token_type: 'Bearer',
            expires_at: Math.floor(Date.now() / 1000) + 3600,
            expires_in: 3600,
            scope: 'ai_gateway',
            base_url: 'http://unused.test/v1'
          }),
          requestAppConfigure: async request => ({
            request_id: request.request_id,
            agent_uid: request.agent_uid,
            values: {
              [CodexConfigOverrideKey]: {
                source: 'global',
                value: { mode: 'official_subscription', config_toml: 'model = "test"' }
              }
            }
          }),
          getSubagentDelegation: async () => delegation,
          appendSubagentDelegationEvents: async request => ({
            request_id: request.request_id,
            delegation_id: request.delegation_id,
            events: request.events.map(event => ({ seq: event.seq, event_id: `event-${event.seq}` })),
            last_event_seq: request.events.at(-1)?.seq
          }),
          updateSubagentDelegationStatus: async request => {
            statusUpdates.push(request)
            return { ...delegation, status: request.status, runtime_thread_id: request.runtime_thread_id }
          },
          requestAgentConversationContext: async request => ({
            request_id: request.request_id,
            agent_uid: 'agent-1',
            session_id: `subagent:${delegationId}`,
            turn: request.turn,
            conversation: {},
            soul: 'SOUL',
            mission: 'MISSION',
            skills: [],
            memory_notes: [],
            cache_key: 'context'
          })
        })
      ).rejects.toThrow('compaction failed')

      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 10_000)
})

function turnStart(): TurnStart {
  return {
    turn: {
      actor: { agent_uid: 'agent-1', session_id: `subagent:${delegationId}` },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      queue_sequence: 1,
      type: 'subagent.delegation.dispatch',
      source_event_id: 'subagent-dispatch-1',
      payload_json: { data: { delegation_id: delegationId, parent_session_id: 'parent-session', attempts: 1 } }
    },
    request_context: {
      turn_mode: 'subagent_delegation',
      delegation_id: delegationId,
      parent_session_id: 'parent-session',
      attempts: 1
    }
  }
}

function response(): SubagentDelegationResponse {
  return {
    request_id: 'get-1',
    delegation_id: delegationId,
    agent_uid: 'agent-1',
    session_id: 'parent-session',
    status: 'running',
    runtime: 'codex',
    title: 'Prepare launch brief',
    prompt: 'Write and verify the launch brief.',
    reply_route: { binding_name: 'lark', signal_channel_id: 'chat-1' },
    attempts: 1,
    workdir: '/workspace/user-files/subagent/019f0000',
    queued_at: new Date(0).toISOString(),
    result: {},
    error: {},
    metadata: {}
  }
}

function steerTurnStart(): TurnStart {
  const base = turnStart()
  return {
    ...base,
    actor_event: {
      ...base.actor_event,
      actor_event_id: '00000000-0000-0000-0000-000000000002',
      type: 'command.steer',
      source_event_id: 'subagent-steer-1',
      payload_json: {
        type: 'command.steer',
        data: {
          command: {
            argsText: 'Use the collected answer.',
            answers: { audience: 'Operators' }
          }
        }
      }
    },
    turn: {
      ...base.turn,
      activation_uid: 'activation-2',
      actor_epoch: 2,
      actor_event_id: '00000000-0000-0000-0000-000000000002'
    },
    request_context: { ...base.request_context, attempts: 2, actor_event_type: 'command.steer' }
  }
}

function writeFakeCodex(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { writeFileSync } from 'node:fs'
let buffer = ''
let threadStartCount = 0
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
async function handle(message) {
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  if (message.method === 'initialized') return
  if (message.method === 'thread/start') {
    threadStartCount += 1
    writeFileSync('thread-start.json', JSON.stringify(message.params))
    return write({ id: message.id, result: { thread: { id: 'thread-' + threadStartCount } } })
  }
  if (message.method === 'thread/compact/start') {
    writeFileSync('compact-called.txt', 'yes')
    write({ id: message.id, result: {} })
    setTimeout(() => {
      write({ method: 'turn/started', params: { turn: { id: 'compact-turn-1', status: 'in_progress' } } })
      write({ method: 'item/completed', params: { threadId: message.params.threadId, turnId: 'compact-turn-1', item: { type: 'contextCompaction', id: 'compact-item-1' } } })
    }, 20)
    return
  }
  if (message.method === 'turn/start') {
    const countPath = 'turn-start-count.txt'
    const countExists = await Bun.file(countPath).exists()
    const count = (Number(countExists ? await Bun.file(countPath).text() : '0') || 0) + 1
    writeFileSync(countPath, String(count))
    write({ id: message.id, result: { turn: { id: 'turn-' + count, status: 'in_progress' } } })
    setTimeout(() => {
      if (count === 1) return write({ method: 'turn/completed', params: { turn: { id: 'turn-1', status: 'failed', error: { message: 'context full', codexErrorInfo: 'contextWindowExceeded' } } } })
      if (count === 2) return write({ method: 'turn/completed', params: { turn: { id: 'turn-2', status: 'failed', error: { message: 'unknown thread: no rollout found', codexErrorInfo: 'other' } } } })
      if (count === 3) return write({ method: 'turn/completed', params: { turn: { id: 'turn-3', status: 'failed', error: { message: 'capacity', codexErrorInfo: 'serverOverloaded' } } } })
      write({ method: 'thread/tokenUsage/updated', params: { tokenUsage: { last: { totalTokens: 21, inputTokens: 16, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 3 } } } })
      write({ method: 'turn/diff/updated', params: { diff: '--- a/removed.md\\n+++ /dev/null\\n--- /dev/null\\n+++ b/brief.md\\n' } })
      write({ method: 'item/agentMessage/delta', params: { delta: 'done' } })
      write({ method: 'turn/completed', params: { turn: { id: 'turn-' + count, status: 'completed' } } })
    }, 20)
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

function writeCompactionFailureFakeCodex(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
let buffer = ''
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function handle(message) {
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  if (message.method === 'initialized') return
  if (message.method === 'thread/start') return write({ id: message.id, result: { thread: { id: 'thread-compact-failure' } } })
  if (message.method === 'turn/start') {
    write({ id: message.id, result: { turn: { id: 'turn-overflow', status: 'in_progress' } } })
    setTimeout(() => write({ method: 'turn/completed', params: { turn: { id: 'turn-overflow', status: 'failed', error: { message: 'context full', codexErrorInfo: 'contextWindowExceeded' } } } }), 10)
    return
  }
  if (message.method === 'thread/compact/start') {
    write({ id: message.id, result: {} })
    setTimeout(() => {
      write({ method: 'turn/started', params: { turn: { id: 'compact-turn-failed', status: 'in_progress' } } })
      write({ method: 'turn/completed', params: { turn: { id: 'compact-turn-failed', status: 'failed', error: { message: 'compaction failed', codexErrorInfo: 'internalServerError' } } } })
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

function writeWaitingFakeCodex(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { writeFileSync } from 'node:fs'
let buffer = ''
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function inputText(params) { return (params.input || []).map(item => item.text || '').join('\\n') }
function handle(message) {
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  if (message.method === 'initialized') return
  if (message.method === 'thread/start') return write({ id: message.id, result: { thread: { id: 'thread-wait' } } })
  if (message.method === 'thread/resume') return write({ id: message.id, error: { message: 'unknown thread: no rollout found' } })
  if (message.method === 'turn/start') {
    const text = inputText(message.params)
    write({ id: message.id, result: { turn: { id: text.includes('Answers to your questions') ? 'turn-2' : 'turn-1' } } })
    if (text.includes('Answers to your questions')) {
      writeFileSync('resume-input.txt', text)
      setTimeout(() => {
        write({ method: 'item/agentMessage/delta', params: { delta: 'resumed' } })
        write({ method: 'turn/completed', params: { turn: { id: 'turn-2', status: 'completed' } } })
      }, 20)
    } else {
      setTimeout(() => write({
        id: 'request-input-1',
        method: 'item/tool/requestUserInput',
        params: { questions: [{ id: 'audience', question: 'Who is the audience?', options: [] }] }
      }), 20)
    }
    return
  }
  if (message.method === 'turn/interrupt') {
    write({ method: 'turn/completed', params: { turn: { id: 'turn-1', status: 'interrupted' } } })
    return write({ id: message.id, result: {} })
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
    --bind|--ro-bind) if [[ "\${3:-}" == "/workspace" ]]; then workspace_src="$2"; fi; shift 3 ;;
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

function workdirFor(root: string): string {
  return join(root, 'sessions', 'agent-1', 'parent-session', 'user-files', 'subagent', '019f0000')
}
