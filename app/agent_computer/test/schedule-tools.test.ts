import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import type { JsonObject } from '@pleisto/active-support'
import { rpcMethods, type RpcMethod, type ScheduleRpcRequest } from '../src/lanes/rpc_lane'
import { createScheduleTools } from '../src/tools/schedule/schedule-tools'

describe('schedule tools', () => {
  it('uses a stable default check_back_later idempotency key across provider tool call retries', async () => {
    const requests: ScheduleRpcRequest[] = []
    const tools = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRpc: async (method: RpcMethod, request: ScheduleRpcRequest): Promise<JsonObject> => {
        expect(method).toBe(rpcMethods.scheduleCheckBackLaterCreate)
        requests.push(request)
        return { status: 'scheduled' }
      }
    })

    const checkBackLater = tools.find(tool => tool.name === 'check_back_later')
    expect(checkBackLater).toBeDefined()

    const params = {
      reason: 'follow up on the research note',
      check: 'Run the backtest if the user still wants it.',
      context_summary: 'The group discussed a strategy from a report.',
      after: { value: 5, unit: 'minute' as const },
      timezone: 'Etc/UTC'
    }

    await checkBackLater!.execute('call_first', params)
    await checkBackLater!.execute('call_retry', params)

    expect(requests).toHaveLength(2)
    expect(requests[0]!.tool_call_id).toBe('call_first')
    expect(requests[1]!.tool_call_id).toBe('call_retry')
    expect(requests[0]!.idempotency_key).toBe(requests[1]!.idempotency_key)
    expect(
      String(requests[0]!.idempotency_key).startsWith('check_back_later:00000000-0000-0000-0000-000000000123:')
    ).toBe(true)
  })

  it('keeps explicit check_back_later idempotency keys unchanged', async () => {
    const requests: ScheduleRpcRequest[] = []
    const [checkBackLater] = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRpc: async (_method: RpcMethod, request: ScheduleRpcRequest): Promise<JsonObject> => {
        requests.push(request)
        return { status: 'scheduled' }
      }
    })

    await checkBackLater!.execute('call_explicit', {
      reason: 'follow up',
      check: 'check status',
      at: '2026-07-03T12:00:00Z',
      idempotency_key: 'operator-provided-key'
    })

    expect(requests[0]!.idempotency_key).toBe('operator-provided-key')
  })

  it('uses a stable default cron:add idempotency key across provider tool call retries', async () => {
    const requests: ScheduleRpcRequest[] = []
    const tools = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRpc: async (method: RpcMethod, request: ScheduleRpcRequest): Promise<JsonObject> => {
        expect(method).toBe(rpcMethods.scheduleCronAdd)
        requests.push(request)
        return { status: 'created' }
      }
    })

    const cron = tools.find(tool => tool.name === 'cron')
    expect(cron).toBeDefined()

    const params = {
      action: 'add' as const,
      name: 'market-open-check',
      schedule: {
        kind: 'every' as const,
        every_ms: 86_400_000,
        anchor_at: '2026-07-03T01:30:00Z'
      },
      payload: { task: 'refresh strategy watchlist' },
      delivery: { quiet_success: true }
    }

    await cron!.execute('call_first', params)
    await cron!.execute('call_retry', params)

    expect(requests).toHaveLength(2)
    expect(requests[0]!.idempotency_key).toBe(requests[1]!.idempotency_key)
    expect(String(requests[0]!.idempotency_key).startsWith('cron:add:00000000-0000-0000-0000-000000000123:')).toBe(true)
  })

  it('keeps explicit cron:add idempotency keys unchanged', async () => {
    const requests: ScheduleRpcRequest[] = []
    const cron = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRpc: async (_method: RpcMethod, request: ScheduleRpcRequest): Promise<JsonObject> => {
        requests.push(request)
        return { status: 'created' }
      }
    }).find(tool => tool.name === 'cron')

    await cron!.execute('call_explicit', {
      action: 'add',
      name: 'operator-keyed-cron',
      schedule: {
        kind: 'cron',
        expression: '0 9 * * 1-5',
        timezone: 'Asia/Shanghai'
      },
      idempotency_key: 'operator-cron-key'
    })

    expect(requests[0]!.idempotency_key).toBe('operator-cron-key')
  })

  it('makes cron-origin turns read-only to prevent recursive schedule mutation', async () => {
    const requests: ScheduleRpcRequest[] = []
    const cron = createScheduleTools({
      turnStart: turnStartForScheduleTool({ cronOrigin: true }),
      requestScheduleRpc: async (_method: RpcMethod, request: ScheduleRpcRequest): Promise<JsonObject> => {
        requests.push(request)
        return { status: 'created' }
      }
    }).find(tool => tool.name === 'cron')

    await expect(
      cron!.execute('call_cron_origin_add', {
        action: 'add',
        name: 'recursive-cron',
        schedule: {
          kind: 'every',
          every_ms: 60_000,
          anchor_at: '2026-07-03T01:30:00Z'
        }
      })
    ).rejects.toThrow('cron-origin turns may only list/get/runs cron schedules')

    expect(requests).toHaveLength(0)
  })

  it('allows cron-origin turns to inspect schedules and run history', async () => {
    const calls: Array<{ method: RpcMethod; request: ScheduleRpcRequest }> = []
    const cron = createScheduleTools({
      turnStart: turnStartForScheduleTool({ cronOrigin: true }),
      requestScheduleRpc: async (method: RpcMethod, request: ScheduleRpcRequest): Promise<JsonObject> => {
        calls.push({ method, request })
        return { status: 'ok', runs: [] }
      }
    }).find(tool => tool.name === 'cron')

    await cron!.execute('call_cron_origin_runs', {
      action: 'runs',
      cron_schedule_id: '00000000-0000-0000-0000-000000000999'
    })

    expect(calls).toHaveLength(1)
    expect(calls[0]!.method).toBe(rpcMethods.scheduleCronRuns)
    expect(calls[0]!.request.cron_schedule_id).toBe('00000000-0000-0000-0000-000000000999')
  })

  it('describes cron as conversational standing-work management with confirmation rules', () => {
    const cron = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRpc: async (): Promise<JsonObject> => ({ status: 'ok' })
    }).find(tool => tool.name === 'cron')

    expect(cron?.description).toContain('standing work')
    expect(cron?.description).toContain('recurring tasks')
    expect(cron?.description).toContain('After add or update')
    expect(cron?.description).toContain('name, schedule/timezone, delivery target')
    expect(cron?.description).toContain('quiet_success=true')
    expect(cron?.description).toContain('visibly report failures')
  })
})

function turnStartForScheduleTool(opts: { cronOrigin?: boolean } = {}): TurnStart {
  return {
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000123',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000123',
      queue_sequence: 1,
      type: 'im.message.addressed',
      source_event_id: 'source-1',
      binding_name: 'mock',
      signal_channel_id: 'mock:chat:schedule',
      provider_thread_id: 'thread-1',
      source_entry_id: 'entry-1',
      payload_json: {}
    },
    ...(opts.cronOrigin
      ? {
          request_context: {
            turn_mode: 'cron',
            schedule_origin: {
              kind: 'cron_fire',
              scheduled_event_id: 'scheduled-event-1'
            }
          }
        }
      : {})
  }
}
