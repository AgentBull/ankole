import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { jsonObject, type JsonObject as JSONObject } from '@pleisto/active-support'
import { genericHash } from '@ankole/kernel'
import { runSubagentTurn } from '../src/core/turns/subagent_turn'
import type {
  SubagentDelegationEventAppendRequest,
  SubagentDelegationResponse,
  SubagentDelegationStatusUpdateRequest
} from '../src/lanes/rpc_lane'
import type { TurnStart, TurnSteerUpdate } from '../src/lanes/actor_lane'
import type { TextTurnLoopOptions } from '../src/core/turns/turn_options'
import { turnFailureDetails } from '../src/worker/active_turns'

const delegationID = '019f0000-0000-7000-8000-000000000001'
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
    let auditAppendAttempts = 0
    const auditAppendRequestIDs: string[] = []
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const activity: string[] = []
    const delegation = response()

    try {
      const result = await runSubagentTurn(turnStart(), {
        workspaceRoot: join(sessionsRoot, 'agent-1', `subagent:${delegationID}`),
        workspaceSessionsRoot: sessionsRoot,
        sharedFsRoot: join(root, 'shared'),
        userFilesRoot,
        requestAIGatewayAPIKey: async request => ({
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          api_key: 'unused',
          token_type: 'Bearer',
          expires_at: Math.floor(Date.now() / 1000) + 3600,
          expires_in: 3600,
          scope: 'ai_gateway',
          base_url: 'http://unused.test/v1'
        }),
        getSubagentDelegation: async () => delegation,
        appendSubagentDelegationEvents: async request => {
          auditAppendAttempts += 1
          auditAppendRequestIDs.push(request.request_id)
          if (auditAppendAttempts === 1) throw new Error('transient audit transport failure')
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
          session_id: `subagent:${delegationID}`,
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
      expect(statusUpdates[0]?.metadata).toMatchObject({
        codex_account_id: 'aigateway',
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
      expect(statusUpdates.at(-1)?.result).toMatchObject({
        report: 'done',
        attempt: 1,
        runtime_thread_id: 'thread-2'
      })
      expect(statusUpdates.at(-1)?.result?.usage).toMatchObject({ totalTokens: 21, outputTokens: 5 })
      expect(statusUpdates.at(-1)?.result?.files_changed).toEqual(['brief.md', 'removed.md'])
      expect(readFileSync(join(workdirFor(root), 'compact-called.txt'), 'utf8')).toBe('yes')
      expect(readFileSync(join(workdirFor(root), 'turn-start-count.txt'), 'utf8')).toBe('4')
      expect(activity).toContain('codex:agent_delta')
      expect(auditBatches.length).toBeGreaterThan(0)
      expect(auditAppendAttempts).toBe(auditBatches.length + 1)
      expect(auditAppendRequestIDs[0]).toBe(auditAppendRequestIDs[1])
      expect(auditBatches.every(batch => batch.events.length <= 20)).toBe(true)
      expect(auditBatches.flatMap(batch => batch.events).every(event => event.payload.attempt === 1)).toBe(true)
      expect(auditBatches.flatMap(batch => batch.events).map(event => event.seq)).toEqual(
        auditBatches.flatMap(batch => batch.events).map((_, index) => index)
      )

      const workdir = workdirFor(root)
      const threadStart = JSON.parse(readFileSync(join(workdir, 'thread-start.json'), 'utf8')) as JSONObject
      expect(String(threadStart.developerInstructions)).toContain('SOUL: Be careful')
      expect(String(threadStart.developerInstructions)).toContain('Background task safety')
      expect(existsSync(join(root, 'shared', '.ankole', 'codex', 'aigateway', 'config.toml'))).toBe(true)
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
      workspaceRoot: join(sessionsRoot, 'agent-1', `subagent:${delegationID}`),
      workspaceSessionsRoot: sessionsRoot,
      sharedFsRoot: join(root, 'shared'),
      userFilesRoot,
      requestAIGatewayAPIKey: async (request: { request_id: string; agent_uid: string }) => ({
        request_id: request.request_id,
        agent_uid: request.agent_uid,
        api_key: 'unused',
        token_type: 'Bearer' as const,
        expires_at: Math.floor(Date.now() / 1000) + 3600,
        expires_in: 3600,
        scope: 'ai_gateway' as const,
        base_url: 'http://127.0.0.1:1/v1'
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
        session_id: `subagent:${delegationID}`,
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
      expect(readFileSync(join(workdir, 'resume-input.txt'), 'utf8')).toContain('Also verify the rollback steps.')
      expect(readFileSync(join(workdir, 'resume-input.txt'), 'utf8')).toContain('risk: Low')
      expect(
        jsonObject(JSON.parse(readFileSync(join(workdir, 'turn-start-request.json'), 'utf8'))).clientUserMessageId
      ).toBe('00000000-0000-0000-0000-000000000002')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 10_000)

  it('keeps the Codex terminal result when active steering loses the completion race', async () => {
    const fixture = prepareControlScenario('steer')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'steer', statusUpdates, auditBatches, {
          pollSteering: () => {
            if (steeringDelivered) return []
            steeringDelivered = true
            return [steerUpdate()]
          },
          onSteeringApplied: async update => {
            appliedSteering.push(update)
          }
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(statusUpdates.at(-1)?.result?.output_text).toBe('completed despite late steer')
      expect(auditBatches.flatMap(batch => batch.events).some(event => event.event_type === 'turn_steer_failed')).toBe(
        true
      )
      expect(appliedSteering).toEqual([])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('delivers active steering to a running Codex turn', async () => {
    const fixture = prepareControlScenario('steer_success')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'steer_success', statusUpdates, auditBatches, {
          pollSteering: () => {
            if (steeringDelivered) return []
            steeringDelivered = true
            return [steerUpdate()]
          },
          onSteeringApplied: async update => {
            appliedSteering.push(update)
          }
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(auditBatches.flatMap(batch => batch.events).some(event => event.event_type === 'turn_steer')).toBe(true)
      expect(appliedSteering.map(update => update.actorEvent?.actor_event_id)).toEqual([
        '00000000-0000-0000-0000-000000000003'
      ])
      expect(
        jsonObject(JSON.parse(readFileSync(join(workdirFor(fixture.root), 'turn-steer.json'), 'utf8')))
          .clientUserMessageId
      ).toBe('00000000-0000-0000-0000-000000000003')
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('carries durable pending steering into recovery turn/start with a stable message id', async () => {
    const fixture = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []

    try {
      const result = await runSubagentTurn(
        turnStartWithPendingSteering(),
        controlScenarioOptions(fixture.root, 'complete', statusUpdates, auditBatches)
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      const request = jsonObject(
        JSON.parse(readFileSync(join(workdirFor(fixture.root), 'turn-start-request.json'), 'utf8'))
      )
      expect(request.clientUserMessageId).toBe('00000000-0000-0000-0000-000000000005')
      expect(JSON.stringify(request.input)).toContain('Preserve the rollback instructions.')
      expect(JSON.stringify(request.input)).toContain('risk: Low')
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('does not create late audit events when completion arrives before the steer response', async () => {
    const fixture = prepareControlScenario('complete_before_steer_response')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'complete_before_steer_response', statusUpdates, auditBatches, {
          pollSteering: () => {
            if (steeringDelivered) return []
            steeringDelivered = true
            return [steerUpdate()]
          },
          onSteeringApplied: async update => {
            appliedSteering.push(update)
          }
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(
        auditBatches
          .flatMap(batch => batch.events)
          .some(event => event.event_type === 'turn_steer' || event.event_type === 'turn_steer_failed')
      ).toBe(false)
      expect(appliedSteering).toEqual([])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('retries the worker attempt when active steering fails before turn completion', async () => {
    const fixture = prepareControlScenario('steer_transport_failure')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      await expect(
        runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'steer_transport_failure', statusUpdates, auditBatches, {
            pollSteering: () => {
              if (steeringDelivered) return []
              steeringDelivered = true
              return [steerUpdate()]
            },
            onSteeringApplied: async update => {
              appliedSteering.push(update)
            }
          })
        )
      ).rejects.toThrow('Subagent steer delivery failed')

      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
      expect(auditBatches.flatMap(batch => batch.events).some(event => event.event_type === 'turn_steer_failed')).toBe(
        true
      )
      expect(appliedSteering).toEqual([])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('interrupts an aborted Codex turn and commits stopped', async () => {
    const fixture = prepareControlScenario('abort')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    const controller = new AbortController()

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'abort', statusUpdates, auditBatches, {
          abortSignal: controller.signal,
          onTurnActivity: description => {
            if (description === 'codex:turn_started') {
              queueMicrotask(() => controller.abort(new Error('operator cancelled delegation')))
            }
          }
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)?.status).toBe('stopped')
      expect(statusUpdates.at(-1)?.metadata?.stop_reason).toContain('operator cancelled delegation')
      expect(readFileSync(join(workdirFor(fixture.root), 'interrupt-called.txt'), 'utf8')).toBe('yes')
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('fails closed when Codex unexpectedly requests command approval', async () => {
    const fixture = prepareControlScenario('approval')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'approval', statusUpdates, auditBatches)
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)?.status).toBe('failed')
      expect(statusUpdates.at(-1)?.error).toMatchObject({ code: 'approval_disabled' })
      expect(
        auditBatches
          .flatMap(batch => batch.events)
          .some(event => {
            const message = jsonObject(event.payload.message)
            return event.direction === 'client_response' && jsonObject(message.result).decision === 'decline'
          })
      ).toBe(true)
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('writes back subscription auth only after Codex changes the account-scoped auth.json', async () => {
    const fixture = prepareControlScenario('official_refresh')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    const initialAuth = '{"tokens":{"account_id":"account-official","access_token":"initial"}}'
    const refreshedAuth = '{"tokens":{"account_id":"account-official","access_token":"refreshed"}}'
    const authUpdates: string[] = []
    const delegation = { ...response(), codex_account_id: 'account-official' }

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'official_refresh', statusUpdates, auditBatches, {
          getSubagentDelegation: async () => delegation,
          resolveCodexAccount: async request => ({
            request_id: request.request_id,
            account_id: 'account-official',
            auth_json: initialAuth,
            auth_hash: genericHash(Buffer.from(initialAuth))
          }),
          updateCodexAccountAuth: async request => {
            authUpdates.push(request.auth_json)
            return {
              request_id: request.request_id,
              account_id: 'account-official'
            }
          }
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(authUpdates).toEqual([refreshedAuth])
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('retries a transient subscription auth writeback before committing success', async () => {
    const fixture = prepareControlScenario('official_refresh')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    const initialAuth = '{"tokens":{"account_id":"account-official","access_token":"initial"}}'
    let updateAttempts = 0

    try {
      await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'official_refresh', statusUpdates, auditBatches, {
          getSubagentDelegation: async () => ({ ...response(), codex_account_id: 'account-official' }),
          resolveCodexAccount: async request => ({
            request_id: request.request_id,
            account_id: 'account-official',
            auth_json: initialAuth,
            auth_hash: genericHash(Buffer.from(initialAuth))
          }),
          updateCodexAccountAuth: async request => {
            updateAttempts += 1
            if (updateAttempts < 3) throw new Error('temporary auth RPC outage')
            return { request_id: request.request_id, account_id: 'account-official' }
          }
        })
      )

      expect(updateAttempts).toBe(3)
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('reconciles refreshed subscription auth when Codex exits before a terminal commit', async () => {
    const fixture = prepareControlScenario('official_refresh_exit')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    const initialAuth = '{"tokens":{"account_id":"account-official","access_token":"initial"}}'
    const authUpdates: string[] = []

    try {
      await expect(
        runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'official_refresh_exit', statusUpdates, auditBatches, {
            getSubagentDelegation: async () => ({ ...response(), codex_account_id: 'account-official' }),
            resolveCodexAccount: async request => ({
              request_id: request.request_id,
              account_id: 'account-official',
              auth_json: initialAuth,
              auth_hash: genericHash(Buffer.from(initialAuth))
            }),
            updateCodexAccountAuth: async request => {
              authUpdates.push(request.auth_json)
              return { request_id: request.request_id, account_id: 'account-official' }
            }
          })
        )
      ).rejects.toThrow()

      expect(authUpdates).toEqual(['{"tokens":{"account_id":"account-official","access_token":"refreshed"}}'])
      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('uses the completed agent message and asks once for a missing final report', async () => {
    const fixture = prepareControlScenario('empty_then_report')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []

    try {
      await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'empty_then_report', statusUpdates, auditBatches)
      )

      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(statusUpdates.at(-1)?.result?.output_text).toBe('final report after retry')
      expect(auditBatches.flatMap(batch => batch.events).some(event => event.event_type === 'empty_report_retry')).toBe(
        true
      )
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('retries exhausted audit persistence as infrastructure failure instead of reporting task failure', async () => {
    const fixture = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []

    try {
      await expect(
        runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'complete', statusUpdates, auditBatches, {
            appendSubagentDelegationEvents: async () => {
              throw new Error('audit transport unavailable')
            }
          })
        )
      ).rejects.toThrow('audit transport unavailable')

      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('does not retry an explicit audit rejection', async () => {
    const fixture = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    let appendCalls = 0

    try {
      let rejection: unknown

      try {
        await runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'complete', statusUpdates, auditBatches, {
            appendSubagentDelegationEvents: async request => {
              appendCalls += 1
              return {
                request_id: request.request_id,
                code: 'subagent_event_sequence_conflict',
                message: 'divergent audit sequence'
              }
            }
          })
        )
      } catch (error) {
        rejection = error
      }

      expect(rejection).toBeInstanceOf(Error)
      expect((rejection as Error).message).toContain('subagent_event_sequence_conflict')
      expect(turnFailureDetails(rejection)).toMatchObject({
        error_code: 'subagent_audit_persistence_rejected',
        retryable: false
      })
      expect(appendCalls).toBe(1)
      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('retries when terminal status is fenced by newly pending steering', async () => {
    const fixture = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const auditBatches: SubagentDelegationEventAppendRequest[] = []
    const delegation = response()
    let rejection: unknown

    try {
      try {
        await runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'complete', statusUpdates, auditBatches, {
            updateSubagentDelegationStatus: async request => {
              statusUpdates.push(request)
              if (request.status === 'succeeded') {
                return {
                  request_id: request.request_id,
                  code: 'subagent_pending_steer',
                  message: 'terminal commit must include the newly accepted steering command'
                }
              }
              return { ...delegation, status: request.status, runtime_thread_id: request.runtime_thread_id }
            }
          })
        )
      } catch (error) {
        rejection = error
      }

      expect(turnFailureDetails(rejection)).toMatchObject({
        error_code: 'subagent_pending_steer',
        retryable: true
      })
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'succeeded'])
    } finally {
      fixture.cleanup()
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
          workspaceRoot: join(sessionsRoot, 'agent-1', `subagent:${delegationID}`),
          workspaceSessionsRoot: sessionsRoot,
          sharedFsRoot: join(root, 'shared'),
          userFilesRoot,
          requestAIGatewayAPIKey: async request => ({
            request_id: request.request_id,
            agent_uid: request.agent_uid,
            api_key: 'unused',
            token_type: 'Bearer',
            expires_at: Math.floor(Date.now() / 1000) + 3600,
            expires_in: 3600,
            scope: 'ai_gateway',
            base_url: 'http://unused.test/v1'
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
            session_id: `subagent:${delegationID}`,
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
      actor: { agent_uid: 'agent-1', session_id: `subagent:${delegationID}` },
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
      payload_json: { data: { delegation_id: delegationID, parent_session_id: 'parent-session', attempts: 1 } }
    },
    request_context: {
      turn_mode: 'subagent_delegation',
      delegation_id: delegationID,
      parent_session_id: 'parent-session',
      attempts: 1
    }
  }
}

function response(): SubagentDelegationResponse {
  return {
    request_id: 'get-1',
    delegation_id: delegationID,
    agent_uid: 'agent-1',
    session_id: 'parent-session',
    status: 'running',
    runtime: 'codex',
    codex_account_id: 'aigateway',
    title: 'Prepare launch brief',
    prompt: 'Write and verify the launch brief.',
    reply_route: { binding_name: 'lark', signal_channel_id: 'chat-1' },
    attempts: 1,
    attempt_history: [{ attempt: 0, event_types: ['status_failed'], summary: 'Prior worker exited.' }],
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
    request_context: {
      ...base.request_context,
      attempts: 2,
      actor_event_type: 'command.steer',
      pending_steering: [
        {
          actor_event_id: '00000000-0000-0000-0000-000000000004',
          text: 'Also verify the rollback steps.',
          answers: { risk: 'Low' }
        }
      ]
    }
  }
}

function steerUpdate(): TurnSteerUpdate {
  const base = turnStart()
  return {
    turn: { ...base.turn, revision: 1 },
    actorEvent: {
      ...base.actor_event,
      actor_event_id: '00000000-0000-0000-0000-000000000003',
      type: 'command.steer',
      source_event_id: 'subagent-active-steer-1',
      payload_json: {
        type: 'command.steer',
        data: { command: { argsText: 'Include the late operator note.' } }
      }
    }
  }
}

function turnStartWithPendingSteering(): TurnStart {
  const base = turnStart()
  return {
    ...base,
    request_context: {
      ...base.request_context,
      attempts: 2,
      pending_steering: [
        {
          actor_event_id: '00000000-0000-0000-0000-000000000005',
          text: 'Preserve the rollback instructions.',
          answers: { risk: 'Low' }
        }
      ]
    }
  }
}

type ControlScenario =
  | 'abort'
  | 'approval'
  | 'complete'
  | 'complete_before_steer_response'
  | 'empty_then_report'
  | 'official_refresh'
  | 'official_refresh_exit'
  | 'steer'
  | 'steer_success'
  | 'steer_transport_failure'

type ControlScenarioOverrides = Partial<
  Pick<
    TextTurnLoopOptions,
    | 'abortSignal'
    | 'appendSubagentDelegationEvents'
    | 'onSteeringApplied'
    | 'onTurnActivity'
    | 'pollSteering'
    | 'getSubagentDelegation'
    | 'resolveCodexAccount'
    | 'updateCodexAccountAuth'
    | 'updateSubagentDelegationStatus'
  >
>

function controlScenarioOptions(
  root: string,
  scenario: ControlScenario,
  statusUpdates: SubagentDelegationStatusUpdateRequest[],
  auditBatches: SubagentDelegationEventAppendRequest[],
  overrides: ControlScenarioOverrides = {}
): TextTurnLoopOptions {
  const delegation = response()
  const sessionsRoot = join(root, 'sessions')
  const userFilesRoot = join(root, 'user-files')

  return {
    workspaceRoot: join(sessionsRoot, 'agent-1', `subagent:${delegationID}`),
    workspaceSessionsRoot: sessionsRoot,
    sharedFsRoot: join(root, 'shared'),
    userFilesRoot,
    requestAIGatewayAPIKey: async request => ({
      request_id: request.request_id,
      agent_uid: request.agent_uid,
      api_key: 'unused',
      token_type: 'Bearer',
      expires_at: Math.floor(Date.now() / 1000) + 3600,
      expires_in: 3600,
      scope: 'ai_gateway',
      base_url: 'http://unused.test/v1'
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
    requestAgentConversationContext: async request => ({
      request_id: request.request_id,
      agent_uid: 'agent-1',
      session_id: `subagent:${delegationID}`,
      turn: request.turn,
      conversation: {},
      soul: 'SOUL',
      mission: 'MISSION',
      skills: [],
      memory_notes: [],
      cache_key: 'context'
    }),
    ...overrides
  }
}

function prepareControlScenario(scenario: ControlScenario): {
  root: string
  cleanup: () => void
} {
  const root = mkdtempSync(join(tmpdir(), `ankole-subagent-${scenario}-`))
  const fakeCodex = join(root, 'fake-codex-control')
  const fakeBwrap = join(root, 'fake-bwrap')
  mkdirSync(join(root, 'sessions'), { recursive: true })
  mkdirSync(join(root, 'user-files'), { recursive: true })
  writeFakeBwrap(fakeBwrap)
  writeControlFakeCodex(fakeCodex, scenario, join(root, 'shared', '.ankole', 'codex', 'account-official', 'auth.json'))
  process.env.ANKOLE_CODEX_BINARY = fakeCodex
  process.env.ANKOLE_BWRAP_PATH = fakeBwrap
  return { root, cleanup: () => rmSync(root, { recursive: true, force: true }) }
}

function writeControlFakeCodex(path: string, scenario: ControlScenario, authPath: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { writeFileSync } from 'node:fs'
let buffer = ''
let turnCount = 0
const scenario = ${JSON.stringify(scenario)}
const authPath = ${JSON.stringify(authPath)}
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function complete(text) {
  write({ method: 'item/agentMessage/delta', params: { delta: 'intermediate progress that is not the final report' } })
  write({ method: 'item/completed', params: { item: { type: 'agentMessage', id: 'agent-message-' + turnCount, text } } })
  write({ method: 'turn/completed', params: { turn: { id: 'turn-control', status: 'completed' } } })
}
function handle(message) {
  if (message.id === 'approval-1' && message.result) return
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  if (message.method === 'initialized') return
  if (message.method === 'thread/start') return write({ id: message.id, result: { thread: { id: 'thread-control' } } })
  if (message.method === 'turn/start') {
    turnCount += 1
    writeFileSync('turn-start-request.json', JSON.stringify(message.params))
    write({ id: message.id, result: { turn: { id: 'turn-control', status: 'in_progress' } } })
    if (scenario === 'approval') {
      setTimeout(() => write({ id: 'approval-1', method: 'item/commandExecution/requestApproval', params: { command: 'true' } }), 20)
    } else if (scenario === 'complete' || scenario === 'official_refresh') {
      if (scenario === 'official_refresh') {
        writeFileSync(authPath, '{"tokens":{"account_id":"account-official","access_token":"refreshed"}}')
      }
      setTimeout(() => complete('completed with audit outage'), 20)
    } else if (scenario === 'empty_then_report') {
      setTimeout(() => complete(turnCount === 1 ? '' : 'final report after retry'), 20)
    } else if (scenario === 'official_refresh_exit') {
      writeFileSync(authPath, '{"tokens":{"account_id":"account-official","access_token":"refreshed"}}')
      setTimeout(() => process.exit(1), 20)
    }
    return
  }
  if (message.method === 'turn/steer') {
    writeFileSync('turn-steer.json', JSON.stringify(message.params))
    if (scenario === 'steer_success') {
      write({ id: message.id, result: {} })
      setTimeout(() => complete('completed after steer'), 20)
      return
    }
    if (scenario === 'complete_before_steer_response') {
      complete('completed before steer response')
      write({ id: message.id, error: { code: -32000, message: 'turn already completed' } })
      return
    }
    if (scenario === 'steer_transport_failure') {
      write({ id: message.id, error: { code: -32001, message: 'connection reset' } })
      return
    }
    write({ id: message.id, error: { code: -32000, message: 'turn already completed' } })
    setTimeout(() => complete('completed despite late steer'), 20)
    return
  }
  if (message.method === 'turn/interrupt') {
    writeFileSync('interrupt-called.txt', 'yes')
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
      write({ method: 'item/agentMessage/delta', params: { delta: 'not the final report' } })
      write({ method: 'item/completed', params: { item: { type: 'agentMessage', id: 'agent-message-' + count, text: 'done' } } })
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
    writeFileSync('turn-start-request.json', JSON.stringify(message.params))
    const text = inputText(message.params)
    write({ id: message.id, result: { turn: { id: text.includes('Answers to your questions') ? 'turn-2' : 'turn-1' } } })
    if (text.includes('Answers to your questions')) {
      writeFileSync('resume-input.txt', text)
      setTimeout(() => {
        write({ method: 'item/agentMessage/delta', params: { delta: 'not the final report' } })
        write({ method: 'item/completed', params: { item: { type: 'agentMessage', id: 'agent-message-resumed', text: 'resumed' } } })
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
