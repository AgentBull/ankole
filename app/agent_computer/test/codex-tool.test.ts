import { describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { CodexConfigOverrideKey, materializeCodexConfig, parseCodexConfigOverride } from '../src/tools/codex/config'
import { createCodexDelegateTool } from '../src/tools/codex/codex-tool'
import { CodexDelegationManager } from '../src/tools/codex/manager'
import { CodexAppServerClient } from '../src/tools/codex/app-server-client'
import { turnStartForTest, sleep } from './support/llm'
import type {
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  AppConfigureResolveRequest,
  AppConfigureResolveResponse,
  CodexDelegationCreateRequest,
  CodexDelegationEventAppendRequest,
  CodexDelegationGetRequest,
  CodexDelegationRejected,
  CodexDelegationResponse,
  CodexDelegationStatusUpdateRequest
} from '../src/lanes/rpc_lane'

describe('@ankole/agent-computer Codex delegation', () => {
  it('materializes default AIGateway config and official subscription overrides in isolated CODEX_HOME', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-config-'))

    try {
      const defaultConfig = materializeCodexConfig({
        workspaceRoot: root,
        delegationId: 'delegation-aigateway',
        override: null,
        aiGatewayKey: aiGatewayKey('agent-1')
      })

      const defaultToml = readFileSync(join(defaultConfig.codexHome, 'config.toml'), 'utf8')
      expect(defaultToml).toContain('model = "coding"')
      expect(defaultToml).toContain('model_provider = "ankole_aigateway"')
      expect(defaultToml).toContain('approval_policy = "never"')
      expect(defaultToml).toContain('sandbox_mode = "danger-full-access"')
      expect(defaultToml).toContain('base_url = "http://aigateway.test/v1"')
      expect(defaultConfig.env.CODEX_HOME).toBe(defaultConfig.codexHome)
      expect(defaultConfig.env.ANKOLE_AIGATEWAY_API_KEY).toBe('sk-aigateway')

      const override = parseCodexConfigOverride({
        mode: 'official_subscription',
        config_toml: 'model = "gpt-5-codex"\n',
        auth_json: { tokens: { id_token: 'id-token' } },
        env: { OPENAI_API_KEY: 'sk-subscription' }
      })

      const subscriptionConfig = materializeCodexConfig({
        workspaceRoot: root,
        delegationId: 'delegation-subscription',
        override,
        aiGatewayKey: aiGatewayKey('agent-1')
      })

      expect(subscriptionConfig.codexHome.startsWith(root)).toBe(false)
      expect(readFileSync(join(subscriptionConfig.codexHome, 'config.toml'), 'utf8')).toBe('model = "gpt-5-codex"\n')
      expect(readFileSync(join(subscriptionConfig.codexHome, 'auth.json'), 'utf8')).toContain('id-token')
      expect(subscriptionConfig.env.OPENAI_API_KEY).toBe('sk-subscription')
      expect(subscriptionConfig.env.ANKOLE_AIGATEWAY_API_KEY).toBeUndefined()
      if (subscriptionConfig.cleanupRoot) rmSync(subscriptionConfig.cleanupRoot, { recursive: true, force: true })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('limits running Codex background delegations to three per agent and queues overflow', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-queue-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 3000)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const manager = new CodexDelegationManager()
    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []
    const requesters = codexRequesters(events, statusUpdates)

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })

      const submissions = await Promise.all(
        [0, 1, 2, 3].map(index =>
          manager.submit({
            turnStart: turnStartForTest(),
            workspaceRoot: root,
            toolCallId: `tool-${index}`,
            request: {
              prompt: `edit task ${index}`,
              workdir: '/workspace/repo',
              timeoutSeconds: 10
            },
            requesters
          })
        )
      )

      await waitUntil(() => {
        const statuses = submissions.map(snapshot => manager.get(snapshot.delegation_id)?.status)
        return statuses.filter(status => status === 'running').length === 3 && statuses.includes('queued')
      })

      const statuses = submissions.map(snapshot => manager.get(snapshot.delegation_id)?.status)
      expect(statuses.filter(status => status === 'running')).toHaveLength(3)
      expect(statuses.filter(status => status === 'queued')).toHaveLength(1)
      expect(events.some(event => event.direction === 'queue' && event.event_type === 'queued')).toBe(true)
      expect(
        new Set(statusUpdates.filter(update => update.status === 'running').map(update => update.delegation_id)).size
      ).toBe(3)
    } finally {
      await Promise.allSettled(
        Array.from({ length: 4 }, (_, index) => manager.stop(`delegation-${index + 1}`).catch(() => null))
      )
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('runs the model-facing codex_delegate self-iteration story through app-server audit', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-tool-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })
      const tool = createCodexDelegateTool({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        ...codexRequesters(events, statusUpdates, 'delegation-tool')
      })

      const result = await tool.execute('tool-call-self-iteration', {
        action: 'run',
        prompt:
          'Self-iterate on the repo: inspect the current code, make a safe improvement, run the focused test, and report.',
        workdir: '/workspace/repo',
        timeout_seconds: 5
      })

      expect(result.details.status).toBe('succeeded')
      expect(result.details.output_text).toBe('done')
      const firstContent = result.content[0]
      expect(firstContent?.type).toBe('text')
      if (firstContent?.type !== 'text') throw new Error('codex_delegate should return text content')
      expect(firstContent.text).toContain('status: succeeded')
      expect(events.some(event => event.direction === 'client_to_server' && event.event_type === 'json_rpc')).toBe(true)
      expect(events.some(event => event.direction === 'server_to_client' && event.event_type === 'json_rpc')).toBe(true)
      expect(events.some(event => event.direction === 'audit' && event.event_type === 'status_succeeded')).toBe(true)
      expect(statusUpdates.some(update => update.status === 'succeeded')).toBe(true)
      expect(result.details.last_event_seq).toBeGreaterThanOrEqual(0)
      expect(result.details.result_ref).toEqual({
        type: 'codex_delegation',
        delegation_id: result.details.delegation_id
      })
      await waitUntil(() => !existsSync(join(root, 'temp', 'codex', result.details.delegation_id)))
    } finally {
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('reads delegation status from the control plane when local worker memory has no job', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-status-db-'))
    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []

    try {
      const tool = createCodexDelegateTool({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        ...codexRequesters(events, statusUpdates, 'delegation-db'),
        getCodexDelegationStatus: async (request: CodexDelegationGetRequest): Promise<CodexDelegationResponse> => ({
          request_id: request.request_id,
          delegation_id: request.delegation_id,
          agent_uid: request.agent_uid,
          session_id: 'session-1',
          status: 'succeeded',
          workdir: '/workspace/repo',
          queued_at: new Date(0).toISOString(),
          completed_at: new Date(1).toISOString(),
          result: { output_text: 'db result' },
          last_event_seq: 7,
          result_ref: { type: 'codex_delegation', delegation_id: request.delegation_id }
        })
      })

      const result = await tool.execute('tool-status-db', {
        action: 'status',
        delegation_id: 'delegation-db-1'
      })

      expect(result.details.status).toBe('succeeded')
      expect(result.details.output_text).toBe('db result')
      expect(result.details.last_event_seq).toBe(7)
      expect(result.details.result_ref).toEqual({
        type: 'codex_delegation',
        delegation_id: 'delegation-db-1'
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails a delegation promptly when the Codex app-server exits mid-turn', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-exit-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20, { exitAfterTurnStart: true })
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })
      const manager = new CodexDelegationManager()
      const submitted = await manager.submit({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        toolCallId: 'tool-exit',
        request: {
          prompt: 'Exit before completion.',
          workdir: '/workspace/repo',
          timeoutSeconds: 30
        },
        requesters: codexRequesters(events, statusUpdates, 'delegation-exit')
      })

      const result = await manager.wait(submitted.delegation_id)

      expect(result.status).toBe('failed')
      expect(result.error).toContain('codex app-server exited')
      expect(statusUpdates.some(update => update.status === 'failed')).toBe(true)
    } finally {
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails a delegation instead of leaking async errors when audit append is rejected', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-audit-failure-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })
      const manager = new CodexDelegationManager()
      const submitted = await manager.submit({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        toolCallId: 'tool-audit-failure',
        request: {
          prompt: 'Complete normally, but audit append fails.',
          workdir: '/workspace/repo',
          timeoutSeconds: 5
        },
        requesters: codexRequesters(events, statusUpdates, 'delegation-audit-failure', { rejectEventSeq: 2 })
      })

      const result = await manager.wait(submitted.delegation_id)

      expect(result.status).toBe('failed')
      expect(result.error).toContain('audit event rejected at seq 2')
      expect(events.some(event => event.seq === 2)).toBe(true)
      expect(statusUpdates.some(update => update.status === 'failed')).toBe(true)
    } finally {
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('does not expose success locally when the final status update is rejected', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-final-status-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })
      const manager = new CodexDelegationManager()
      const submitted = await manager.submit({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        toolCallId: 'tool-final-status',
        request: {
          prompt: 'Complete normally, but terminal status update fails.',
          workdir: '/workspace/repo',
          timeoutSeconds: 5
        },
        requesters: codexRequesters(events, statusUpdates, 'delegation-final-status', {
          rejectStatusUpdate: 'succeeded'
        })
      })

      const result = await manager.wait(submitted.delegation_id)

      expect(result.status).toBe('failed')
      expect(result.error).toContain('Codex finalization failed')
      expect(result.error).toContain('codex_status_rejected')
      expect(statusUpdates.some(update => update.status === 'succeeded')).toBe(true)
    } finally {
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('responds with method-not-found when a server request arrives without a handler', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-no-request-handler-'))
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20, { requestUserInput: true })
    const audits: Array<{ direction: string; message: Record<string, unknown> }> = []
    const client = new CodexAppServerClient({
      command: fakeCodex,
      cwd: root,
      env: { PATH: process.env.PATH ?? '' },
      audit: (direction, message) => audits.push({ direction, message })
    })

    try {
      await client.initialize()
      const threadStart = (await client.request('thread/start', {})) as { thread?: { id?: string } }
      await client.request('turn/start', { threadId: threadStart.thread?.id, input: textInputForTest('ask') })
      await waitUntil(() =>
        audits.some(
          audit =>
            audit.direction === 'client_response' &&
            typeof audit.message.error === 'object' &&
            audit.message.error !== null
        )
      )
    } finally {
      await client.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('bridges requestUserInput into waiting_on_user and continues after steer', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-user-input-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20, { requestUserInput: true })
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })
      const manager = new CodexDelegationManager()
      const submitted = await manager.submit({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        toolCallId: 'tool-user-input',
        request: {
          prompt: 'Ask one question then continue.',
          workdir: '/workspace/repo',
          timeoutSeconds: 5
        },
        requesters: codexRequesters(events, statusUpdates, 'delegation-user-input')
      })

      const waiting = await manager.wait(submitted.delegation_id)
      expect(waiting.status).toBe('waiting_on_user')
      expect(waiting.waiting_on_user).toBeDefined()

      const steered = await manager.steer(submitted.delegation_id, 'Use React state.')
      expect(steered.status).toBe('running')

      await waitUntil(() => manager.get(submitted.delegation_id)?.status === 'succeeded')
      expect(manager.get(submitted.delegation_id)?.output_text).toContain('answered')
      expect(events.some(event => event.event_type === 'request_user_input')).toBe(true)
      expect(events.some(event => event.event_type === 'user_input_answered')).toBe(true)
      expect(statusUpdates.some(update => update.status === 'waiting_on_user')).toBe(true)
    } finally {
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects Codex approval requests and records the failure', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-approval-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20, { requestApproval: true })
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })
      const manager = new CodexDelegationManager()
      const submitted = await manager.submit({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        toolCallId: 'tool-approval',
        request: {
          prompt: 'Request approval.',
          workdir: '/workspace/repo',
          timeoutSeconds: 5
        },
        requesters: codexRequesters(events, statusUpdates, 'delegation-approval')
      })

      const result = await manager.wait(submitted.delegation_id)

      expect(result.status).toBe('failed')
      expect(result.error).toContain('approvals are disabled')
      expect(events.some(event => event.event_type === 'approval_rejected')).toBe(true)
      expect(statusUpdates.some(update => update.status === 'failed')).toBe(true)
    } finally {
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps a delegation queued and retries when the control plane rejects the global per-agent running slot', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-global-queue-'))
    const previousBinary = process.env.ANKOLE_CODEX_BINARY
    const fakeCodex = join(root, 'fake-codex')
    writeFakeCodex(fakeCodex, 20)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex

    const manager = new CodexDelegationManager()
    const events: CodexDelegationEventAppendRequest[] = []
    const statusUpdates: CodexDelegationStatusUpdateRequest[] = []
    const requesters = codexRequesters(events, statusUpdates, 'delegation-global', {
      rejectRunningAttempts: 1
    })

    try {
      mkdirSync(join(root, 'repo'), { recursive: true })
      const submitted = await manager.submit({
        turnStart: turnStartForTest(),
        workspaceRoot: root,
        toolCallId: 'tool-global-slot',
        request: {
          prompt: 'Implement a tiny change and report.',
          workdir: '/workspace/repo',
          timeoutSeconds: 5
        },
        requesters
      })

      await waitUntil(() => events.some(event => event.event_type === 'global_running_limit_deferred'))
      expect(manager.get(submitted.delegation_id)?.status).toBe('queued')

      await waitUntil(() => manager.get(submitted.delegation_id)?.status === 'succeeded', 3000)
      expect(statusUpdates.filter(update => update.status === 'running').length).toBeGreaterThanOrEqual(2)
    } finally {
      await manager.stop('delegation-global-1').catch(() => null)
      if (previousBinary === undefined) {
        delete process.env.ANKOLE_CODEX_BINARY
      } else {
        process.env.ANKOLE_CODEX_BINARY = previousBinary
      }
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function aiGatewayKey(agentUid: string): AIGatewayApiKeyResponse {
  return {
    request_id: 'aigateway-key-1',
    agent_uid: agentUid,
    api_key: 'sk-aigateway',
    token_type: 'Bearer',
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    expires_in: 3600,
    scope: 'ai_gateway',
    base_url: 'http://aigateway.test/v1/'
  }
}

function codexRequesters(
  events: CodexDelegationEventAppendRequest[],
  statusUpdates: CodexDelegationStatusUpdateRequest[],
  delegationPrefix = 'delegation',
  opts: { rejectRunningAttempts?: number; rejectEventSeq?: number; rejectStatusUpdate?: string } = {}
) {
  let nextDelegation = 1
  let rejectedRunningAttempts = 0

  return {
    requestAIGatewayApiKey: async (request: AIGatewayApiKeyRequest) => aiGatewayKey(request.agent_uid),
    requestAppConfigure: async (request: AppConfigureResolveRequest): Promise<AppConfigureResolveResponse> => ({
      request_id: request.request_id,
      agent_uid: request.agent_uid,
      values: {
        [CodexConfigOverrideKey]: { value: null, source: 'default' }
      }
    }),
    createCodexDelegation: async (request: CodexDelegationCreateRequest): Promise<CodexDelegationResponse> => {
      const delegationId = `${delegationPrefix}-${nextDelegation++}`
      return {
        request_id: request.request_id,
        delegation_id: delegationId,
        agent_uid: request.agent_uid,
        session_id: request.session_id,
        status: request.status ?? 'queued',
        metadata: request.metadata
      }
    },
    appendCodexDelegationEvent: async (request: CodexDelegationEventAppendRequest) => {
      events.push(request)
      if (request.seq === opts.rejectEventSeq) {
        throw new Error(`audit event rejected at seq ${request.seq}`)
      }
      return { request_id: request.request_id, event_id: `event-${request.seq}` }
    },
    updateCodexDelegationStatus: async (
      request: CodexDelegationStatusUpdateRequest
    ): Promise<CodexDelegationResponse | CodexDelegationRejected> => {
      statusUpdates.push(request)
      if (request.status === 'running' && rejectedRunningAttempts < (opts.rejectRunningAttempts ?? 0)) {
        rejectedRunningAttempts += 1
        return {
          request_id: request.request_id,
          delegation_id: request.delegation_id,
          agent_uid: request.agent_uid,
          session_id: 'session-1',
          status: 'queued',
          code: 'codex_agent_running_limit_exceeded',
          message: 'per-agent Codex delegation running limit reached'
        }
      }
      if (request.status === opts.rejectStatusUpdate) {
        return {
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          code: 'codex_status_rejected',
          message: `${request.status} status rejected`
        }
      }
      return {
        request_id: request.request_id,
        delegation_id: request.delegation_id,
        agent_uid: request.agent_uid,
        session_id: 'session-1',
        status: request.status ?? 'running',
        codex_thread_id: request.codex_thread_id
      }
    }
  }
}

function writeFakeCodex(
  path: string,
  completionDelayMs: number,
  opts: { exitAfterTurnStart?: boolean; requestUserInput?: boolean; requestApproval?: boolean } = {}
): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
let buffer = ''
let nextTurn = 1
const completionDelayMs = ${completionDelayMs}
const opts = ${JSON.stringify(opts)}
let pendingUserInput = false
let pendingApproval = false
function write(message) {
  process.stdout.write(JSON.stringify(message) + '\\n')
}
function handle(message) {
  if (message.method === 'initialize') {
    write({ id: message.id, result: { protocolVersion: '0.1.0', capabilities: {} } })
    return
  }
  if (message.method === 'initialized') return
  if (message.method === 'thread/start') {
    write({ id: message.id, result: { thread: { id: 'thread-' + message.id } } })
    return
  }
  if (message.method === 'turn/start') {
    const turnId = 'turn-' + nextTurn++
    write({ id: message.id, result: { turn: { id: turnId, status: 'in_progress' } } })
    if (opts.exitAfterTurnStart) {
      setTimeout(() => process.exit(42), completionDelayMs)
      return
    }
    if (opts.requestUserInput) {
      setTimeout(() => {
        pendingUserInput = true
        write({
          id: 'request-user-input-1',
          method: 'item/tool/requestUserInput',
          params: { questions: [{ id: 'direction', question: 'Which direction?', options: [] }] }
        })
      }, completionDelayMs)
      return
    }
    if (opts.requestApproval) {
      setTimeout(() => {
        pendingApproval = true
        write({
          id: 'approval-1',
          method: 'item/commandExecution/requestApproval',
          params: { command: 'rm -rf /workspace' }
        })
      }, completionDelayMs)
      return
    }
    setTimeout(() => {
      write({ method: 'item/agentMessage/delta', params: { delta: 'done' } })
      write({ method: 'turn/completed', params: { turn: { id: turnId, status: 'completed' } } })
    }, completionDelayMs)
    return
  }
  if (message.id === 'request-user-input-1' && pendingUserInput) {
    pendingUserInput = false
    setTimeout(() => {
      write({ method: 'item/agentMessage/delta', params: { delta: 'answered' } })
      write({ method: 'turn/completed', params: { turn: { id: 'turn-steered', status: 'completed' } } })
    }, completionDelayMs)
    return
  }
  if (message.id === 'approval-1' && pendingApproval) {
    pendingApproval = false
    return
  }
  if (message.method === 'turn/interrupt') {
    write({ id: message.id, result: {} })
    process.exit(0)
    return
  }
  if (message.id !== undefined) write({ id: message.id, result: {} })
}
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  buffer += chunk
  let newlineIndex = buffer.indexOf('\\n')
  while (newlineIndex >= 0) {
    const line = buffer.slice(0, newlineIndex).trim()
    buffer = buffer.slice(newlineIndex + 1)
    if (line) handle(JSON.parse(line))
    newlineIndex = buffer.indexOf('\\n')
  }
})
`,
    { mode: 0o755 }
  )
  chmodSync(path, 0o755)
}

function textInputForTest(text: string): Array<Record<string, unknown>> {
  return [{ type: 'text', text, text_elements: [] }]
}

async function waitUntil(predicate: () => boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await sleep(25)
  }
  throw new Error('condition was not met before deadline')
}
