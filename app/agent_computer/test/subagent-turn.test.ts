import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { jsonObject, type JsonObject as JSONObject } from '@pleisto/active-support'
import { genericHash } from '@ankole/kernel'
import { runSubagentTurn } from '../src/core/turns/subagent_turn'
import type {
  SubagentDelegationTurnUpsertRequest,
  SubagentDelegationResponse,
  SubagentDelegationStatusUpdateRequest
} from '../src/lanes/rpc_lane'
import type { TurnStart, TurnSteerUpdate } from '../src/lanes/actor_lane'
import type { TextTurnLoopOptions } from '../src/core/turns/turn_options'
import { CODEX_OPT_OUT_NOTIFICATION_METHODS } from '../src/tools/codex/app-server-client'
import { turnFailureDetails } from '../src/worker/active_turns'

const delegationID = '019f0000-0000-7000-8000-000000000001'
const previousCodexBinary = process.env.ANKOLE_CODEX_BINARY
const previousBwrap = process.env.ANKOLE_BWRAP_PATH

afterEach(() => {
  restoreEnv('ANKOLE_CODEX_BINARY', previousCodexBinary)
  restoreEnv('ANKOLE_BWRAP_PATH', previousBwrap)
})

describe('@ankole/agent-computer subagent turn', () => {
  it('assembles one durable trajectory row per Codex Turn and commits success before noop', async () => {
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

    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    let turnUpsertAttempts = 0
    const turnUpsertRequestIDs: string[] = []
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const activity: string[] = []
    const persistenceOrder: string[] = []
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
        upsertSubagentDelegationTurn: async request => {
          turnUpsertAttempts += 1
          turnUpsertRequestIDs.push(request.request_id)
          if (turnUpsertAttempts === 1) throw new Error('transient Turn transport failure')
          if (request.runtime_thread_id === 'thread-1' && request.runtime_turn_id === 'turn-2') {
            await Bun.sleep(25)
          }
          turnUpserts.push(request)
          persistenceOrder.push(`turn:${request.runtime_thread_id}:${request.runtime_turn_id}:${request.status}`)
          return turnUpsertResponse(request)
        },
        updateSubagentDelegationStatus: async request => {
          statusUpdates.push(request)
          persistenceOrder.push(`delegation:${request.runtime_thread_id ?? 'none'}:${request.status}`)
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
          brain_snapshot: {}
        })
      })

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'running', 'succeeded'])
      expect(statusUpdates[0]?.metadata).toMatchObject({
        codex_account_id: 'aigateway',
        codex_user_agent: 'codex-cli 0.144.0',
        browser_execution_scope: `subagent:${delegationID}`,
        projected_tool_names: expect.arrayContaining(['web_search', 'web_fetch', 'browser_navigate']),
        quarantined_tool_names: [],
        shared_skill_count: 0
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
      expect(statusUpdates.at(-1)?.result?.usage).toMatchObject({
        thread_total: { total_tokens: 55, output_tokens: 15 },
        last_model_call: { total_tokens: 21, output_tokens: 5 },
        model_context_window: 200_000
      })
      expect(statusUpdates.at(-1)?.result?.files_changed).toEqual(['brief.md', 'removed.md'])
      expect(readFileSync(join(workdirFor(root), 'compact-called.txt'), 'utf8')).toBe('yes')
      expect(readFileSync(join(workdirFor(root), 'turn-start-count.txt'), 'utf8')).toBe('4')
      expect(activity).toContain('codex:agent_completed')
      expect(activity).not.toContain('codex:agent_delta')
      expect(turnUpserts.length).toBeGreaterThan(0)
      expect(turnUpsertAttempts).toBe(turnUpserts.length + 1)
      expect(turnUpsertRequestIDs[0]).toBe(turnUpsertRequestIDs[1])
      expect(turnUpserts.every(turn => turn.attempt === 1)).toBe(true)
      expect(turnUpserts.every(turn => turn.trajectory.format === 'ankole_chatml')).toBe(true)
      expect(turnUpserts.some(turn => JSON.stringify(turn.trajectory).includes('item/agentMessage/delta'))).toBe(false)
      expect(new Set(turnUpserts.map(turn => turn.runtime_turn_id)).size).toBeGreaterThan(1)
      expect(persistenceOrder.indexOf('turn:thread-1:turn-2:failed')).toBeLessThan(
        persistenceOrder.indexOf('delegation:thread-2:running')
      )
      const completed = turnUpserts.filter(turn => turn.status === 'completed').at(-1)
      expect(completed?.trajectory.messages).toEqual(
        expect.arrayContaining([expect.objectContaining({ role: 'assistant', content: 'done' })])
      )

      const workdir = workdirFor(root)
      const firstTurnStart = JSON.parse(readFileSync(join(workdir, 'turn-start-1.json'), 'utf8')) as JSONObject
      expect((firstTurnStart.input as JSONObject[])[0]?.text).toBe(delegation.task)
      expect(firstTurnStart).not.toHaveProperty('collaborationMode')
      const threadStart = JSON.parse(readFileSync(join(workdir, 'thread-start.json'), 'utf8')) as JSONObject
      expect(threadStart).not.toHaveProperty('developerInstructions')
      const initialize = JSON.parse(readFileSync(join(workdir, 'initialize.json'), 'utf8')) as JSONObject
      expect(jsonObject(initialize.capabilities).optOutNotificationMethods).toEqual([
        ...CODEX_OPT_OUT_NOTIFICATION_METHODS
      ])
      expect(existsSync(join(root, 'shared', '.ankole', 'codex', 'aigateway', 'config.toml'))).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 15_000)

  it('validates the Deep Research delivery and persists the same normalized Turn trajectory', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-deep-research-turn-'))
    const sessionsRoot = join(root, 'sessions')
    const userFilesRoot = join(root, 'user-files')
    const sharedFsRoot = join(root, 'shared')
    const fakeCodex = join(root, 'fake-codex-deep-research')
    const fakeBwrap = join(root, 'fake-bwrap')
    const installedSkillsRoot = join(root, 'installed-skills')
    const builtinSkillsRoot = join(import.meta.dir, '..', '..', 'library', 'skills')
    const delegation = {
      ...deepResearchResponse(),
      metadata: {
        output_schema: {
          type: 'object',
          required: ['answer'],
          properties: { answer: { const: 'Aurora has an approved budget of 10 units.' } }
        }
      }
    }
    const workdir = join(userFilesRoot, 'research', delegationID)
    mkdirSync(sessionsRoot, { recursive: true })
    mkdirSync(userFilesRoot, { recursive: true })
    mkdirSync(installedSkillsRoot, { recursive: true })
    writeGeneralResearchArtifacts(workdir)
    writeFakeBwrap(fakeBwrap)
    writeDeepResearchFakeCodex(fakeCodex)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex
    process.env.ANKOLE_BWRAP_PATH = fakeBwrap

    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    try {
      const result = await runSubagentTurn(
        turnStart(),
        deepResearchTurnOptions({
          sessionsRoot,
          userFilesRoot,
          sharedFsRoot,
          installedSkillsRoot,
          builtinSkillsRoot,
          delegation,
          statusUpdates,
          turnUpserts
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)).toMatchObject({ status: 'succeeded' })
      expect(statusUpdates.at(-1)?.result).toMatchObject({
        schema_version: 'deep_research_result_v1',
        mode: 'general',
        stop_reason: 'completed'
      })
      expect(statusUpdates[0]?.metadata).toMatchObject({
        projected_tool_names: expect.arrayContaining([
          'web_search',
          'web_fetch',
          'browser_navigate',
          'browser_snapshot',
          'research_validate_delivery'
        ]),
        shared_skill_count: 1
      })
      const terminalTurn = turnUpserts.filter(update => update.status === 'completed').at(-1)!
      expect(terminalTurn.runtime_turn_id).toBe('turn-deep-research')
      expect(terminalTurn.trajectory).toMatchObject({ format: 'ankole_chatml', version: 1 })
      expect(terminalTurn.trajectory.messages).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ role: 'user', content: expect.stringContaining(delegation.task.trim()) }),
          expect.objectContaining({ role: 'assistant', content: 'Research complete.' })
        ])
      )
      const turnStartRequest = JSON.parse(readFileSync(join(workdir, 'turn-start-request.json'), 'utf8'))
      expect(turnStartRequest).not.toHaveProperty('collaborationMode')
      expect(readFileSync(join(sharedFsRoot, '.ankole', 'codex', 'aigateway', 'config.toml'), 'utf8')).toContain(
        '[features.multi_agent_v2]\nenabled = true\nhide_spawn_agent_metadata = true'
      )
      expect(turnUpserts.length).toBeGreaterThan(0)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 15_000)

  it('forces a budget-capped Deep Research submission without opening new collection', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-deep-research-budget-'))
    const sessionsRoot = join(root, 'sessions')
    const userFilesRoot = join(root, 'user-files')
    const sharedFsRoot = join(root, 'shared')
    const fakeCodex = join(root, 'fake-codex-deep-research-budget')
    const fakeBwrap = join(root, 'fake-bwrap')
    const installedSkillsRoot = join(root, 'installed-skills')
    const builtinSkillsRoot = join(import.meta.dir, '..', '..', 'library', 'skills')
    const delegation = deepResearchResponse()
    mkdirSync(sessionsRoot, { recursive: true })
    mkdirSync(userFilesRoot, { recursive: true })
    mkdirSync(installedSkillsRoot, { recursive: true })
    writeGeneralResearchArtifacts(join(userFilesRoot, 'research', delegationID))
    writeFakeBwrap(fakeBwrap)
    writeBudgetDeepResearchFakeCodex(fakeCodex)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex
    process.env.ANKOLE_BWRAP_PATH = fakeBwrap

    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    try {
      const result = await runSubagentTurn(
        turnStart(),
        deepResearchTurnOptions({
          sessionsRoot,
          userFilesRoot,
          sharedFsRoot,
          installedSkillsRoot,
          builtinSkillsRoot,
          delegation,
          statusUpdates,
          turnUpserts,
          wallclockBudget: 25,
          submissionGrace: 0
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)).toMatchObject({
        status: 'failed',
        result: {
          schema_version: 'deep_research_result_v1',
          mode: 'general',
          stop_reason: 'budget_capped',
          codex_turn_status: 'budget_exhausted'
        },
        error: { code: 'research_budget_exhausted' },
        metadata: { forced_submission: true, budget_exhausted: true }
      })
      expect(turnUpserts.at(-1)).toMatchObject({
        status: 'interrupted',
        error: { code: 'budget_exhausted' }
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 5_000)

  it('keeps the budget-capped outcome when Codex finishes during submission grace', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-deep-research-budget-grace-'))
    const sessionsRoot = join(root, 'sessions')
    const userFilesRoot = join(root, 'user-files')
    const sharedFsRoot = join(root, 'shared')
    const fakeCodex = join(root, 'fake-codex-deep-research-budget-grace')
    const fakeBwrap = join(root, 'fake-bwrap')
    const installedSkillsRoot = join(root, 'installed-skills')
    const builtinSkillsRoot = join(import.meta.dir, '..', '..', 'library', 'skills')
    const delegation = deepResearchResponse()
    mkdirSync(sessionsRoot, { recursive: true })
    mkdirSync(userFilesRoot, { recursive: true })
    mkdirSync(installedSkillsRoot, { recursive: true })
    writeGeneralResearchArtifacts(join(userFilesRoot, 'research', delegationID))
    writeFakeBwrap(fakeBwrap)
    writeBudgetDeepResearchFakeCodex(fakeCodex, true)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex
    process.env.ANKOLE_BWRAP_PATH = fakeBwrap

    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    try {
      const result = await runSubagentTurn(
        turnStart(),
        deepResearchTurnOptions({
          sessionsRoot,
          userFilesRoot,
          sharedFsRoot,
          installedSkillsRoot,
          builtinSkillsRoot,
          delegation,
          statusUpdates,
          turnUpserts,
          wallclockBudget: 25,
          submissionGrace: 1_000
        })
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)).toMatchObject({
        status: 'succeeded',
        result: {
          schema_version: 'deep_research_result_v1',
          mode: 'general',
          stop_reason: 'budget_capped',
          codex_turn_status: 'completed'
        },
        metadata: { forced_submission: true }
      })
      expect(turnUpserts.at(-1)?.status).toBe('completed')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 5_000)

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
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
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
      upsertSubagentDelegationTurn: async (request: SubagentDelegationTurnUpsertRequest) => {
        turnUpserts.push(request)
        return turnUpsertResponse(request)
      },
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
        brain_snapshot: {}
      })
    }

    try {
      const waitingResult = await runSubagentTurn(turnStart(), options)
      expect(waitingResult.kind).toBe('noop_completed')
      const waiting = updates.find(update => update.status === 'waiting_on_user')
      expect(waiting?.metadata?.pending_user_input).toMatchObject({
        questions: [{ id: 'audience', question: 'Who is the audience?' }]
      })
      expect(turnUpserts.filter(turn => turn.runtime_turn_id === 'turn-1').at(-1)).toMatchObject({
        status: 'interrupted',
        error: { code: 'request_user_input' }
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

  it('rejects child requestUserInput without pausing the lead delegation', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-child-input-'))
    const fakeCodex = join(root, 'fake-codex-child-input')
    const fakeBwrap = join(root, 'fake-bwrap')
    mkdirSync(join(root, 'sessions'), { recursive: true })
    mkdirSync(join(root, 'user-files'), { recursive: true })
    writeFakeBwrap(fakeBwrap)
    writeChildRequestUserInputFakeCodex(fakeCodex)
    process.env.ANKOLE_CODEX_BINARY = fakeCodex
    process.env.ANKOLE_BWRAP_PATH = fakeBwrap

    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(root, 'steer', statusUpdates, turnUpserts)
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(statusUpdates.some(update => update.status === 'waiting_on_user')).toBe(false)
      expect(JSON.stringify(turnUpserts)).not.toContain('pending_user_input')
      expect(readFileSync(join(workdirFor(root), 'child-request-error.txt'), 'utf8')).toContain(
        'return the question to the lead agent'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 10_000)

  it('keeps the Codex terminal result when active steering loses the completion race', async () => {
    const fixture = prepareControlScenario('steer')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'steer', statusUpdates, turnUpserts, {
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
      expect(turnUpserts.at(-1)?.status).toBe('completed')
      expect(appliedSteering).toEqual([])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('delivers active steering to a running Codex turn', async () => {
    const fixture = prepareControlScenario('steer_success')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'steer_success', statusUpdates, turnUpserts, {
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
      expect(turnUpserts.at(-1)?.trajectory.messages).toEqual(
        expect.arrayContaining([expect.objectContaining({ role: 'user', content: 'Include the late operator note.' })])
      )
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
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []

    try {
      const result = await runSubagentTurn(
        turnStartWithPendingSteering(),
        controlScenarioOptions(fixture.root, 'complete', statusUpdates, turnUpserts)
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

  it('does not mutate the terminal Turn when completion arrives before the steer response', async () => {
    const fixture = prepareControlScenario('complete_before_steer_response')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'complete_before_steer_response', statusUpdates, turnUpserts, {
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
      expect(turnUpserts.at(-1)?.status).toBe('completed')
      expect(appliedSteering).toEqual([])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('retries the worker attempt when active steering fails before turn completion', async () => {
    const fixture = prepareControlScenario('steer_transport_failure')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    let steeringDelivered = false
    const appliedSteering: TurnSteerUpdate[] = []

    try {
      await expect(
        runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'steer_transport_failure', statusUpdates, turnUpserts, {
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
      expect(turnUpserts.at(-1)).toMatchObject({ status: 'failed' })
      expect(appliedSteering).toEqual([])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('interrupts an aborted Codex turn and commits stopped', async () => {
    const fixture = prepareControlScenario('abort')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    const controller = new AbortController()

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'abort', statusUpdates, turnUpserts, {
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

  it('accepts Codex command approval and lets the same turn finish', async () => {
    const fixture = prepareControlScenario('approval')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'approval', statusUpdates, turnUpserts)
      )

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(turnUpserts.at(-1)).toMatchObject({ status: 'completed' })
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('writes back subscription auth only after Codex changes the account-scoped auth.json', async () => {
    const fixture = prepareControlScenario('official_refresh')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    const initialAuth = '{"tokens":{"account_id":"account-official","access_token":"initial"}}'
    const refreshedAuth = '{"tokens":{"account_id":"account-official","access_token":"refreshed"}}'
    const authUpdates: string[] = []
    const delegation = { ...response(), codex_account_id: 'account-official' }

    try {
      const result = await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'official_refresh', statusUpdates, turnUpserts, {
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
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    const initialAuth = '{"tokens":{"account_id":"account-official","access_token":"initial"}}'
    let updateAttempts = 0

    try {
      await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'official_refresh', statusUpdates, turnUpserts, {
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
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    const initialAuth = '{"tokens":{"account_id":"account-official","access_token":"initial"}}'
    const authUpdates: string[] = []

    try {
      await expect(
        runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'official_refresh_exit', statusUpdates, turnUpserts, {
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
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []

    try {
      await runSubagentTurn(
        turnStart(),
        controlScenarioOptions(fixture.root, 'empty_then_report', statusUpdates, turnUpserts)
      )

      expect(statusUpdates.at(-1)?.status).toBe('succeeded')
      expect(statusUpdates.at(-1)?.result?.output_text).toBe('final report after retry')
      expect(new Set(turnUpserts.map(turn => turn.runtime_turn_id)).size).toBe(2)
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('reports exhausted Turn persistence as infrastructure failure instead of task failure', async () => {
    const fixture = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []

    try {
      await expect(
        runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'complete', statusUpdates, turnUpserts, {
            upsertSubagentDelegationTurn: async () => {
              throw new Error('Turn transport unavailable')
            }
          })
        )
      ).rejects.toThrow('Turn transport unavailable')

      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('does not retry an explicit Turn persistence rejection', async () => {
    const fixture = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    let upsertCalls = 0

    try {
      let rejection: unknown

      try {
        await runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'complete', statusUpdates, turnUpserts, {
            upsertSubagentDelegationTurn: async request => {
              upsertCalls += 1
              return {
                request_id: request.request_id,
                code: 'subagent_turn_revision_conflict',
                message: 'divergent Turn revision'
              }
            }
          })
        )
      } catch (error) {
        rejection = error
      }

      expect(rejection).toBeInstanceOf(Error)
      expect((rejection as Error).message).toContain('subagent_turn_revision_conflict')
      expect(turnFailureDetails(rejection)).toMatchObject({
        error_code: 'subagent_turn_persistence_rejected',
        retryable: false
      })
      expect(upsertCalls).toBe(1)
      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('retries when terminal status is fenced by newly pending steering', async () => {
    const fixture = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    const delegation = response()
    let rejection: unknown

    try {
      try {
        await runSubagentTurn(
          turnStart(),
          controlScenarioOptions(fixture.root, 'complete', statusUpdates, turnUpserts, {
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

  it('resumes the same persisted thread across a second execution after transient retry exhaustion', async () => {
    const fixture = prepareControlScenario('transient_exhausted_then_success')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    const delegation = (attempts: number): SubagentDelegationResponse => ({
      ...response(),
      attempts,
      runtime_thread_id: 'thread-existing'
    })
    let failure: unknown

    try {
      try {
        await runSubagentTurn(turnStart(1), {
          ...controlScenarioOptions(fixture.root, 'transient_exhausted_then_success', statusUpdates, turnUpserts, {
            getSubagentDelegation: async () => delegation(1)
          })
        })
      } catch (error) {
        failure = error
      }

      expect(failure).toBeInstanceOf(Error)
      expect(turnFailureDetails(failure)).toMatchObject({
        error_code: 'subagent_codex_transient',
        retryable: true
      })

      const result = await runSubagentTurn(turnStart(2), {
        ...controlScenarioOptions(fixture.root, 'transient_exhausted_then_success', statusUpdates, turnUpserts, {
          getSubagentDelegation: async () => delegation(2)
        })
      })

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'running', 'succeeded'])
      expect(statusUpdates.map(update => update.runtime_thread_id)).toEqual([
        'thread-existing',
        'thread-existing',
        'thread-existing'
      ])
      expect(readFileSync(join(workdirFor(fixture.root), 'thread-resume-count.txt'), 'utf8')).toBe('2')
      expect(readFileSync(join(workdirFor(fixture.root), 'turn-start-count.txt'), 'utf8')).toBe('5')
      expect(readFileSync(join(workdirFor(fixture.root), 'partial-report.pdf'), 'utf8')).toBe('partial PDF payload')
      expect(JSON.parse(readFileSync(join(workdirFor(fixture.root), 'turn-thread-ids.json'), 'utf8'))).toEqual([
        'thread-existing',
        'thread-existing',
        'thread-existing',
        'thread-existing',
        'thread-existing'
      ])
      expect(existsSync(join(workdirFor(fixture.root), 'thread-start-called.txt'))).toBe(false)
    } finally {
      fixture.cleanup()
    }
  }, 10_000)

  it('does not override a structured terminal Codex error with message fallback', async () => {
    const fixture = prepareControlScenario('terminal_structured_error')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []

    try {
      const result = await runSubagentTurn(turnStart(), {
        ...controlScenarioOptions(fixture.root, 'terminal_structured_error', statusUpdates, [])
      })

      expect(result).toEqual({ kind: 'noop_completed', reason: 'subagent_delegation_committed' })
      expect(statusUpdates.map(update => update.status)).toEqual(['running', 'failed'])
      expect(statusUpdates.at(-1)?.error).toMatchObject({ code: 'unauthorized' })
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
          upsertSubagentDelegationTurn: async request => turnUpsertResponse(request),
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
            brain_snapshot: {}
          })
        })
      ).rejects.toThrow('compaction failed')

      expect(statusUpdates.map(update => update.status)).toEqual(['running'])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 10_000)

  it('fails setup when Codex does not discover an enabled Ankole skill', async () => {
    const { root, cleanup } = prepareControlScenario('complete')
    const statusUpdates: SubagentDelegationStatusUpdateRequest[] = []
    const turnUpserts: SubagentDelegationTurnUpsertRequest[] = []
    const builtinSkillsRoot = join(root, 'builtin-skills')
    const skillRoot = join(builtinSkillsRoot, 'required-skill')
    const installedSkillsRoot = join(root, 'installed-skills')
    mkdirSync(skillRoot, { recursive: true })
    mkdirSync(installedSkillsRoot, { recursive: true })
    writeFileSync(
      join(skillRoot, 'SKILL.md'),
      ['---', 'name: required-skill', 'description: Required test skill.', '---', '', '# Required', ''].join('\n')
    )

    try {
      await expect(
        runSubagentTurn(
          turnStart(),
          controlScenarioOptions(root, 'complete', statusUpdates, turnUpserts, {
            builtinSkillsRoot,
            agentInstalledSkillsRoot: installedSkillsRoot,
            requestAgentConversationContext: async request => ({
              request_id: request.request_id,
              agent_uid: 'agent-1',
              session_id: `subagent:${delegationID}`,
              turn: request.turn,
              conversation: {},
              soul: 'SOUL',
              mission: 'MISSION',
              skills: [{ skill_name: 'required-skill', source_kind: 'builtin', relative_path: 'required-skill' }],
              brain_snapshot: {}
            })
          })
        )
      ).rejects.toThrow('Codex did not discover enabled skills: required-skill')
      expect(statusUpdates).toHaveLength(0)
    } finally {
      cleanup()
    }
  })
})

function turnStart(attempts = 1): TurnStart {
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
      payload_json: { data: { delegation_id: delegationID, parent_session_id: 'parent-session', attempts } }
    },
    request_context: {
      turn_mode: 'subagent_delegation',
      delegation_id: delegationID,
      parent_session_id: 'parent-session',
      attempts
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
    runtime: 'task_worker',
    codex_account_id: 'aigateway',
    title: 'Prepare launch brief',
    task: '\n  Write and verify the launch brief.  \n',
    background: 'The launch brief is for operators.',
    notes: 'Keep the handoff concise.',
    reply_route: { binding_name: 'lark', signal_channel_id: 'chat-1' },
    attempts: 1,
    attempt_history: [{ attempt: 0, turn_statuses: ['failed'], summary: 'Prior worker exited.' }],
    workdir: '/workspace/user-files/subagent/019f0000',
    queued_at: new Date(0).toISOString(),
    result: {},
    error: {},
    metadata: {}
  }
}

function turnUpsertResponse(request: SubagentDelegationTurnUpsertRequest) {
  return {
    request_id: request.request_id,
    delegation_id: request.delegation_id,
    turn: {
      id: `stored:${request.runtime_turn_id}`,
      attempt: request.attempt,
      runtime_thread_id: request.runtime_thread_id,
      runtime_turn_id: request.runtime_turn_id,
      kind: request.kind,
      status: request.status,
      revision: request.revision,
      trajectory: request.trajectory,
      progress: request.progress,
      usage: request.usage ?? null,
      error: request.error ?? {},
      started_at: request.started_at,
      ...(request.completed_at ? { completed_at: request.completed_at } : {})
    }
  }
}

function deepResearchResponse(): Extract<
  SubagentDelegationResponse,
  { runtime: 'deep_research'; mode: 'general' | 'forecast' }
> {
  return {
    request_id: 'get-research-1',
    delegation_id: delegationID,
    agent_uid: 'agent-1',
    session_id: 'parent-session',
    status: 'running',
    runtime: 'deep_research',
    mode: 'general',
    codex_account_id: 'aigateway',
    title: 'Research Aurora',
    task: 'Produce an evidence-backed Deep Research report.',
    reply_route: { binding_name: 'lark', signal_channel_id: 'chat-1' },
    attempts: 1,
    workdir: `/workspace/user-files/research/${delegationID}`,
    result: {},
    error: {},
    metadata: {}
  }
}

function deepResearchTurnOptions(input: {
  sessionsRoot: string
  userFilesRoot: string
  sharedFsRoot: string
  installedSkillsRoot: string
  builtinSkillsRoot: string
  delegation: ReturnType<typeof deepResearchResponse>
  statusUpdates: SubagentDelegationStatusUpdateRequest[]
  turnUpserts: SubagentDelegationTurnUpsertRequest[]
  wallclockBudget?: number
  submissionGrace?: number
}): TextTurnLoopOptions {
  return {
    workspaceRoot: join(input.sessionsRoot, 'agent-1', `subagent:${delegationID}`),
    workspaceSessionsRoot: input.sessionsRoot,
    sharedFsRoot: input.sharedFsRoot,
    userFilesRoot: input.userFilesRoot,
    builtinSkillsRoot: input.builtinSkillsRoot,
    agentInstalledSkillsRoot: input.installedSkillsRoot,
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
    requestAppConfigure: async request => {
      const values: Record<string, { source: string; value: unknown }> = {}
      if (request.keys.includes('agent_computer.deep_research')) {
        values['agent_computer.deep_research'] = {
          source: 'agent',
          value: {
            wallclock_budget: input.wallclockBudget ?? 60_000,
            submission_grace: input.submissionGrace ?? 1_000,
            retention_days: 30
          }
        }
      }
      return { request_id: request.request_id, agent_uid: request.agent_uid, values }
    },
    getSubagentDelegation: async () => input.delegation,
    upsertSubagentDelegationTurn: async request => {
      input.turnUpserts.push(request)
      return turnUpsertResponse(request)
    },
    updateSubagentDelegationStatus: async request => {
      input.statusUpdates.push(request)
      return {
        ...input.delegation,
        status: request.status,
        runtime_thread_id: request.runtime_thread_id
      }
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
      brain_snapshot: {}
    })
  }
}

function writeGeneralResearchArtifacts(workdir: string): void {
  for (const path of ['plan', 'logs', 'evidence/sources', 'evidence/notes', 'report', 'verification'])
    mkdirSync(join(workdir, path), { recursive: true })
  const source = Buffer.from('Project Aurora has an approved budget of 10 units.\n')
  writeFileSync(join(workdir, 'evidence', 'sources', 'aurora.md'), source)
  writeFileSync(
    join(workdir, 'evidence', 'notes', 'aurora.md'),
    '# Aurora evidence\n\nHigh reliability. The approved budget is 10 units [E01].\n'
  )
  writeFileSync(
    join(workdir, 'plan', 'research-plan.md'),
    '# Research plan\n\nUse evidence slots with atom collection mode before synthesis.\n'
  )
  writeFileSync(join(workdir, 'plan', 'attention-notes.md'), '# Attention\n\n- Verify the source amount.\n')
  writeFileSync(join(workdir, 'logs', 'research-log.md'), '# Sufficiency\n\n- S01: Yes — archived source.\n')
  writeFileSync(
    join(workdir, 'plan', 'evidence-slots.json'),
    `${JSON.stringify(
      [
        {
          id: 'S01',
          question: 'What budget was approved?',
          required: true,
          source_types: ['task_fixture'],
          sufficiency: 'One authoritative fixture.',
          mode: 'atom',
          risk: 'normal',
          status: 'satisfied',
          evidence_ids: ['E01']
        }
      ],
      null,
      2
    )}\n`
  )
  writeFileSync(
    join(workdir, 'evidence', 'index.json'),
    `${JSON.stringify(
      [
        {
          id: 'E01',
          source: 'Aurora task fixture',
          retrieved_at: '2026-07-15T00:00:00Z',
          archive_path: 'evidence/sources/aurora.md',
          note_path: 'evidence/notes/aurora.md',
          type: 'task_fixture',
          reliability: 'High',
          archive_kind: 'task_fixture',
          content_hash: genericHash(source),
          excerpt: 'Project Aurora has an approved budget of 10 units.',
          independence_key: 'aurora-fixture',
          supports: ['S01'],
          corroborated_by: []
        }
      ],
      null,
      2
    )}\n`
  )
  writeFileSync(
    join(workdir, 'report', 'outline.md'),
    '## 1. Key Takeaways\n\nQuestion: What budget was approved?\nSummary: State the approved amount.\nStatus: complete\n'
  )
  writeFileSync(
    join(workdir, 'report', 'report.md'),
    '## 1. Key Takeaways\n\nAurora has an approved budget of 10 units [E01].\n\n## References\n\n- [E01] Aurora fixture — evidence/sources/aurora.md\n'
  )
  writeFileSync(
    join(workdir, 'report', 'conclusion.json'),
    `${JSON.stringify(
      {
        schema_version: 'general_conclusion_v1',
        mode: 'general',
        stop_reason: 'completed',
        answer: 'Aurora has an approved budget of 10 units.',
        key_findings: ['Aurora has an approved budget of 10 units.'],
        limitations: [],
        unresolved_conflicts: 0
      },
      null,
      2
    )}\n`
  )
  writeFileSync(
    join(workdir, 'verification', 'review.json'),
    `${JSON.stringify(
      {
        schema_version: 'research_verification_v2',
        task_requirements: [
          {
            id: 'R01',
            requirement: 'State the approved budget.',
            kind: 'substantive',
            claim_ids: ['C01'],
            evidence_ids: ['E01']
          }
        ],
        claims: [
          {
            id: 'C01',
            kind: 'external_fact',
            text: 'Aurora has an approved budget of 10 units [E01].',
            evidence_ids: ['E01']
          }
        ]
      },
      null,
      2
    )}\n`
  )
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
  | 'terminal_structured_error'
  | 'transient_exhausted_then_success'

type ControlScenarioOverrides = Partial<
  Pick<
    TextTurnLoopOptions,
    | 'abortSignal'
    | 'upsertSubagentDelegationTurn'
    | 'onSteeringApplied'
    | 'onTurnActivity'
    | 'pollSteering'
    | 'getSubagentDelegation'
    | 'resolveCodexAccount'
    | 'updateCodexAccountAuth'
    | 'updateSubagentDelegationStatus'
    | 'requestAgentConversationContext'
    | 'builtinSkillsRoot'
    | 'agentInstalledSkillsRoot'
  >
>

function controlScenarioOptions(
  root: string,
  scenario: ControlScenario,
  statusUpdates: SubagentDelegationStatusUpdateRequest[],
  turnUpserts: SubagentDelegationTurnUpsertRequest[],
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
    upsertSubagentDelegationTurn: async request => {
      turnUpserts.push(request)
      return turnUpsertResponse(request)
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
      brain_snapshot: {}
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
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
let buffer = ''
let turnCount = 0
let activeThreadId = 'thread-control'
const scenario = ${JSON.stringify(scenario)}
const authPath = ${JSON.stringify(authPath)}
const transientMessages = [
  'stream disconnected before completion: Transport error: network error: error decoding response body',
  'upstream returned HTTP status 502',
  'upstream returned HTTP status 503',
  'upstream returned HTTP status 504'
]
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function complete(text) {
  const turnId = 'turn-control-' + turnCount
  const itemId = 'agent-message-' + turnCount
  write({ method: 'item/agentMessage/delta', params: { threadId: activeThreadId, turnId, itemId, delta: 'intermediate progress that is not the final report' } })
  write({ method: 'item/completed', params: { threadId: activeThreadId, turnId, item: { type: 'agentMessage', id: itemId, text } } })
  write({ method: 'turn/completed', params: { threadId: activeThreadId, turn: { id: turnId, status: 'completed' } } })
}
function handle(message) {
  if (message.id === 'approval-1' && message.result) return complete('completed after approval')
  if (message.method === 'initialize') {
    writeFileSync('initialize.json', JSON.stringify(message.params))
    return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  }
  if (message.method === 'initialized') return
  if (message.method === 'skills/list') return write({ id: message.id, result: { data: [{ cwd: message.params.cwds[0], skills: [], errors: [] }] } })
  if (message.method === 'thread/resume' && scenario === 'transient_exhausted_then_success') {
    const countPath = 'thread-resume-count.txt'
    const count = (Number(existsSync(countPath) ? readFileSync(countPath, 'utf8') : '0') || 0) + 1
    writeFileSync(countPath, String(count))
    activeThreadId = message.params.threadId
    return write({ id: message.id, result: { thread: { id: activeThreadId } } })
  }
  if (message.method === 'thread/start') {
    if (scenario === 'transient_exhausted_then_success') writeFileSync('thread-start-called.txt', 'yes')
    activeThreadId = 'thread-control'
    return write({ id: message.id, result: { thread: { id: activeThreadId } } })
  }
  if (message.method === 'turn/start') {
    activeThreadId = message.params.threadId
    turnCount += 1
    const turnId = 'turn-control-' + turnCount
    if (scenario === 'transient_exhausted_then_success') {
      const countPath = 'turn-start-count.txt'
      const count = (Number(existsSync(countPath) ? readFileSync(countPath, 'utf8') : '0') || 0) + 1
      const threadIDsPath = 'turn-thread-ids.json'
      const threadIDs = existsSync(threadIDsPath) ? JSON.parse(readFileSync(threadIDsPath, 'utf8')) : []
      threadIDs.push(message.params.threadId)
      writeFileSync(countPath, String(count))
      writeFileSync(threadIDsPath, JSON.stringify(threadIDs))
      if (count === 1) writeFileSync('partial-report.pdf', 'partial PDF payload')
      write({ id: message.id, result: { turn: { id: turnId, status: 'in_progress' } } })
      if (count <= 4) {
        setTimeout(() => write({
          method: 'turn/completed',
          params: {
            turn: {
              id: turnId,
              status: 'failed',
              error: {
                message: transientMessages[count - 1],
                codexErrorInfo: 'other'
              }
            }
          }
        }), 20)
      } else {
        setTimeout(() => complete('completed after durable retry'), 20)
      }
      return
    }
    writeFileSync('turn-start-request.json', JSON.stringify(message.params))
    write({ id: message.id, result: { turn: { id: turnId, status: 'in_progress' } } })
    if (scenario === 'approval') {
      setTimeout(() => write({ id: 'approval-1', method: 'item/commandExecution/requestApproval', params: { command: 'true' } }), 20)
    } else if (scenario === 'complete' || scenario === 'official_refresh') {
      if (scenario === 'official_refresh') {
        writeFileSync(authPath, '{"tokens":{"account_id":"account-official","access_token":"refreshed"}}')
      }
      setTimeout(() => complete('completed with Turn persistence'), 20)
    } else if (scenario === 'empty_then_report') {
      setTimeout(() => complete(turnCount === 1 ? '' : 'final report after retry'), 20)
    } else if (scenario === 'terminal_structured_error') {
      setTimeout(() => write({
        method: 'turn/completed',
        params: {
          turn: {
            id: turnId,
            status: 'failed',
            error: { message: 'response stream closed', codexErrorInfo: 'unauthorized' }
          }
        }
      }), 20)
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

function writeDeepResearchFakeCodex(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { writeFileSync } from 'node:fs'
let buffer = ''
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function handle(message) {
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  if (message.method === 'initialized') return
  if (message.method === 'skills/list') {
    return write({
      id: message.id,
      result: {
        data: [{
          cwd: message.params.cwds[0],
          skills: [{ name: 'deep-research', enabled: true }],
          errors: []
        }]
      }
    })
  }
  if (message.method === 'thread/start') {
    return write({ id: message.id, result: { thread: { id: 'thread-deep-research' } } })
  }
  if (message.method === 'thread/read') {
    throw new Error('Agent Computer must not read raw Codex rollouts')
  }
  if (message.method === 'turn/start') {
    if (message.params.outputSchema) throw new Error('Deep Research output_schema describes report content, not the Codex final message')
    writeFileSync('turn-start-request.json', JSON.stringify(message.params))
    write({ id: message.id, result: { turn: { id: 'turn-deep-research', status: 'in_progress' } } })
    setTimeout(() => {
      write({ method: 'item/completed', params: { threadId: 'thread-deep-research', turnId: 'turn-deep-research', item: { type: 'agentMessage', id: 'agent-message-research', text: 'Research complete.' } } })
      write({ method: 'turn/completed', params: { threadId: 'thread-deep-research', turn: { id: 'turn-deep-research', status: 'completed' } } })
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

function writeBudgetDeepResearchFakeCodex(path: string, completeOnSteer = false): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
let buffer = ''
const completeOnSteer = ${JSON.stringify(completeOnSteer)}
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function handle(message) {
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  if (message.method === 'initialized') return
  if (message.method === 'skills/list') {
    return write({ id: message.id, result: { data: [{ cwd: message.params.cwds[0], skills: [{ name: 'deep-research', enabled: true }], errors: [] }] } })
  }
  if (message.method === 'thread/start') {
    return write({ id: message.id, result: { thread: { id: 'thread-deep-research-budget' } } })
  }
  if (message.method === 'thread/read') {
    throw new Error('Agent Computer must not read raw Codex rollouts')
  }
  if (message.method === 'turn/start') {
    write({ id: message.id, result: { turn: { id: 'turn-deep-research-budget', status: 'in_progress' } } })
    return
  }
  if (message.method === 'turn/interrupt') {
    return write({ id: message.id, result: {} })
  }
  if (message.method === 'turn/steer' && completeOnSteer) {
    write({ id: message.id, result: {} })
    setTimeout(() => {
      write({ method: 'item/completed', params: { threadId: 'thread-deep-research-budget', turnId: 'turn-deep-research-budget', item: { type: 'agentMessage', id: 'agent-message-budget', text: 'Budget-capped research complete.' } } })
      write({ method: 'turn/completed', params: { threadId: 'thread-deep-research-budget', turn: { id: 'turn-deep-research-budget', status: 'completed' } } })
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

function writeFakeCodex(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { writeFileSync } from 'node:fs'
let buffer = ''
let threadStartCount = 0
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
async function handle(message) {
  if (message.method === 'initialize') {
    writeFileSync('initialize.json', JSON.stringify(message.params))
    return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  }
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
      write({ method: 'turn/started', params: { threadId: message.params.threadId, turn: { id: 'compact-turn-1', status: 'inProgress', itemsView: 'full', items: [] } } })
      write({ method: 'item/completed', params: { threadId: message.params.threadId, turnId: 'compact-turn-1', item: { type: 'contextCompaction', id: 'compact-item-1' } } })
    }, 20)
    return
  }
  if (message.method === 'turn/start') {
    const countPath = 'turn-start-count.txt'
    const countExists = await Bun.file(countPath).exists()
    const count = (Number(countExists ? await Bun.file(countPath).text() : '0') || 0) + 1
    writeFileSync(countPath, String(count))
    writeFileSync('turn-start-' + count + '.json', JSON.stringify(message.params))
    write({ id: message.id, result: { turn: { id: 'turn-' + count, status: 'inProgress', itemsView: 'full', items: [] } } })
    setTimeout(() => {
      if (count === 1) return write({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'turn-1', status: 'failed', itemsView: 'notLoaded', items: [], error: { message: 'context full', codexErrorInfo: 'contextWindowExceeded' } } } })
      if (count === 2) return write({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'turn-2', status: 'failed', itemsView: 'notLoaded', items: [], error: { message: 'unknown thread: no rollout found', codexErrorInfo: 'other' } } } })
      if (count === 3) return write({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'turn-3', status: 'failed', itemsView: 'notLoaded', items: [], error: { message: 'capacity', codexErrorInfo: 'serverOverloaded' } } } })
      write({ method: 'thread/tokenUsage/updated', params: { tokenUsage: {
        total: { totalTokens: 55, inputTokens: 40, cachedInputTokens: 10, outputTokens: 15, reasoningOutputTokens: 5 },
        last: { totalTokens: 21, inputTokens: 16, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 3 },
        modelContextWindow: 200000
      } } })
      write({ method: 'turn/diff/updated', params: { diff: '--- a/removed.md\\n+++ /dev/null\\n--- /dev/null\\n+++ b/brief.md\\n' } })
      write({ method: 'item/agentMessage/delta', params: { threadId: message.params.threadId, turnId: 'turn-' + count, itemId: 'agent-message-' + count, delta: 'not the final report' } })
      write({ method: 'item/completed', params: { threadId: message.params.threadId, turnId: 'turn-' + count, item: { type: 'agentMessage', id: 'agent-message-' + count, text: 'done', phase: null, memoryCitation: null } } })
      write({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'turn-' + count, status: 'completed', itemsView: 'summary', items: [{ type: 'agentMessage', id: 'agent-message-' + count, text: 'done', phase: null, memoryCitation: null }] } } })
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
    write({ id: message.id, result: { turn: { id: text.includes('Answers to your questions') ? 'turn-2' : 'turn-1', status: 'inProgress', itemsView: 'full', items: [] } } })
    if (text.includes('Answers to your questions')) {
      writeFileSync('resume-input.txt', text)
      setTimeout(() => {
        write({ method: 'item/agentMessage/delta', params: { threadId: message.params.threadId, turnId: 'turn-2', itemId: 'agent-message-resumed', delta: 'not the final report' } })
        write({ method: 'item/completed', params: { threadId: message.params.threadId, turnId: 'turn-2', item: { type: 'agentMessage', id: 'agent-message-resumed', text: 'resumed', phase: null, memoryCitation: null } } })
        write({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'turn-2', status: 'completed', itemsView: 'summary', items: [{ type: 'agentMessage', id: 'agent-message-resumed', text: 'resumed', phase: null, memoryCitation: null }] } } })
      }, 20)
    } else {
      setTimeout(() => write({
        id: 'request-input-1',
        method: 'item/tool/call',
        params: {
          threadId: message.params.threadId,
          turnId: 'turn-1',
          callId: 'request-input-1',
          namespace: null,
          tool: 'request_parent_input',
          arguments: {
            questions: [{ id: 'audience', header: 'Audience', question: 'Who is the audience?', options: [] }]
          }
        }
      }), 20)
    }
    return
  }
  if (message.method === 'turn/interrupt') {
    write({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'turn-1', status: 'interrupted', itemsView: 'notLoaded', items: [] } } })
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

function writeChildRequestUserInputFakeCodex(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bun
import { writeFileSync } from 'node:fs'
let buffer = ''
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function completeLead() {
  write({ method: 'item/completed', params: { threadId: 'thread-lead', turnId: 'turn-lead', item: { type: 'agentMessage', id: 'agent-message-lead', text: 'done', phase: null, memoryCitation: null } } })
  write({ method: 'turn/completed', params: { threadId: 'thread-lead', turn: { id: 'turn-lead', status: 'completed', itemsView: 'summary', items: [{ type: 'agentMessage', id: 'agent-message-lead', text: 'done', phase: null, memoryCitation: null }] } } })
}
function handle(message) {
  if (message.method === 'initialize') return write({ id: message.id, result: { userAgent: 'codex-cli 0.144.0' } })
  if (message.method === 'initialized') return
  if (message.method === 'thread/start') return write({ id: message.id, result: { thread: { id: 'thread-lead' } } })
  if (message.method === 'turn/start') {
    write({ id: message.id, result: { turn: { id: 'turn-lead', status: 'inProgress', itemsView: 'full', items: [] } } })
    setTimeout(() => write({
      id: 'child-request-input-1',
      method: 'item/tool/requestUserInput',
      params: {
        threadId: 'thread-child',
        turnId: 'turn-child',
        itemId: 'child-input-item',
        questions: [{ id: 'audience', question: 'Who is the audience?', options: [] }]
      }
    }), 20)
    return
  }
  if (message.id === 'child-request-input-1' && message.error) {
    writeFileSync('child-request-error.txt', String(message.error.message || ''))
    return setTimeout(completeLead, 10)
  }
  if (message.method === 'turn/interrupt') {
    write({ id: message.id, result: {} })
    return write({ method: 'turn/completed', params: { threadId: 'thread-lead', turn: { id: 'turn-lead', status: 'interrupted', itemsView: 'notLoaded', items: [] } } })
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
