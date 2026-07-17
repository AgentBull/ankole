import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'
import { rpcMethods, type ScheduleRPCMethod } from '../src/lanes/rpc_lane'
import { createScheduleTools } from '../src/tools/schedule/schedule-tools'

describe('schedule tools', () => {
  it('uses a stable default check_back_later idempotency key across provider tool call retries', async () => {
    const requests: JSONObject[] = []
    const tools = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRPC: async (method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
        expect(method).toBe(rpcMethods.scheduleCheckBackLaterCreate)
        requests.push(request)
        return { status: 'scheduled' }
      }
    })

    const checkBackLater = tools.find(tool => tool.name === 'check_back_later')
    expect(checkBackLater).toBeDefined()

    const params = {
      action: 'create' as const,
      reason: 'follow up on the research note',
      check: 'Run the backtest if the user still wants it.',
      context_summary: 'The group discussed a strategy from a report.',
      schedule: {
        after: { value: 5, unit: 'minute' as const },
        timezone: 'Etc/UTC'
      }
    }

    const result = await checkBackLater!.execute('call_first', params)
    await checkBackLater!.execute('call_retry', params)

    expect(requests).toHaveLength(2)
    expect(requests[0]!.tool_call_id).toBe('call_first')
    expect(requests[1]!.tool_call_id).toBe('call_retry')
    expect(requests[0]!.quiet_success).toBe(false)
    expect(requests[1]!.quiet_success).toBe(false)
    expect(requests[0]!.idempotency_key).toBe(requests[1]!.idempotency_key)
    expect(
      String(requests[0]!.idempotency_key).startsWith('check_back_later:00000000-0000-0000-0000-000000000123:')
    ).toBe(true)
    expect(result.presentation).toEqual([
      expect.objectContaining({
        kind: 'effect.receipt',
        payload: expect.objectContaining({ operation_id: 'call_first', phase: 'confirmed' })
      })
    ])
  })

  it('keeps visible checkbacks on the old default key and separates explicit quiet checkbacks', async () => {
    const requests: JSONObject[] = []
    const checkBackLater = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRPC: async (_method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
        requests.push(request)
        return { status: 'scheduled', quiet_success: request.quiet_success }
      }
    }).find(tool => tool.name === 'check_back_later')

    const params = {
      action: 'create' as const,
      reason: 'follow up on the deployment',
      check: 'Check whether the deployment finished.',
      schedule: {
        after: { value: 5, unit: 'minute' as const },
        timezone: 'Etc/UTC'
      }
    }

    await checkBackLater!.execute('call_omitted', params)
    await checkBackLater!.execute('call_false', { ...params, quiet_success: false })
    await checkBackLater!.execute('call_true', { ...params, quiet_success: true })

    expect(requests.map(request => request.quiet_success)).toEqual([false, false, true])
    expect(requests[0]!.idempotency_key).toBe('check_back_later:00000000-0000-0000-0000-000000000123:6059cf6dc9b5f7ff')
    expect(requests[0]!.idempotency_key).toBe(requests[1]!.idempotency_key)
    expect(requests[2]!.idempotency_key).not.toBe(requests[0]!.idempotency_key)
  })

  it('keeps explicit check_back_later idempotency keys unchanged', async () => {
    const requests: JSONObject[] = []
    const [checkBackLater] = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRPC: async (_method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
        requests.push(request)
        return { status: 'scheduled' }
      }
    })

    await checkBackLater!.execute('call_explicit', {
      action: 'create',
      reason: 'follow up',
      check: 'check status',
      schedule: { at: '2026-07-03T12:00:00Z' },
      idempotency_key: 'operator-provided-key'
    })

    expect(requests[0]!.idempotency_key).toBe('operator-provided-key')
  })

  it('lists, inspects, updates, and cancels durable checkbacks through distinct RPC methods', async () => {
    const calls: Array<{ method: ScheduleRPCMethod; request: JSONObject }> = []
    const checkBackLater = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRPC: async (method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
        calls.push({ method, request })
        return { status: method.endsWith('.cancel') ? 'cancelled' : 'ok' }
      }
    }).find(tool => tool.name === 'check_back_later')
    const scheduledEventID = '019f6259-a538-7750-af5d-8420a85fff58'

    const listed = await checkBackLater!.execute('call_list', { action: 'list', limit: 5 })
    const inspected = await checkBackLater!.execute('call_get', {
      action: 'get',
      scheduled_event_id: scheduledEventID
    })
    const updated = await checkBackLater!.execute('call_update', {
      action: 'update',
      scheduled_event_id: scheduledEventID,
      updates: {
        check: 'Let the evidence determine the PDF length.',
        context_summary: 'The user removed the 6–12 page constraint.'
      }
    })
    const cancelled = await checkBackLater!.execute('call_cancel', {
      action: 'cancel',
      scheduled_event_id: scheduledEventID
    })

    expect(calls.map(call => call.method)).toEqual([
      rpcMethods.scheduleCheckBackLaterList,
      rpcMethods.scheduleCheckBackLaterGet,
      rpcMethods.scheduleCheckBackLaterUpdate,
      rpcMethods.scheduleCheckBackLaterCancel
    ])
    expect(calls[0]!.request.limit).toBe(5)
    expect(calls[1]!.request.scheduled_event_id).toBe(scheduledEventID)
    expect(calls[2]!.request.updates).toEqual({
      check: 'Let the evidence determine the PDF length.',
      context_summary: 'The user removed the 6–12 page constraint.'
    })
    expect(String(calls[2]!.request.idempotency_key)).toStartWith(
      `check_back_later:update:${scheduledEventID}:00000000-0000-0000-0000-000000000123:`
    )
    expect(calls[2]!.request.reply_route).toEqual({
      binding_name: 'mock',
      signal_channel_id: 'mock:chat:schedule',
      provider_thread_id: 'thread-1',
      source_entry_id: 'entry-1'
    })
    expect(calls[3]!.request.scheduled_event_id).toBe(scheduledEventID)
    expect(listed.presentation).toEqual([])
    expect(inspected.presentation).toEqual([])
    expect(updated.presentation).toEqual([
      {
        kind: 'effect.receipt',
        payload: {
          operation_id: 'call_update',
          phase: 'confirmed',
          summary: '已更新后续检查',
          target: scheduledEventID
        }
      }
    ])
    expect(cancelled.presentation).toEqual([
      {
        kind: 'effect.receipt',
        payload: {
          operation_id: 'call_cancel',
          phase: 'confirmed',
          summary: '已取消后续检查',
          target: scheduledEventID
        }
      }
    ])
  })

  it('validates check_back_later update payloads and exposes the action enum to the model', () => {
    const checkBackLater = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRPC: async (): Promise<JSONObject> => ({ status: 'ok' })
    }).find(tool => tool.name === 'check_back_later')

    expect(
      checkBackLater?.schema.safeParse({
        action: 'update',
        scheduled_event_id: '019f6259-a538-7750-af5d-8420a85fff58',
        updates: {}
      }).success
    ).toBe(false)
    expect(
      checkBackLater?.schema.safeParse({
        action: 'update',
        scheduled_event_id: '019f6259-a538-7750-af5d-8420a85fff58',
        updates: { check: 'Use the corrected requirement.' }
      }).success
    ).toBe(true)

    const modelSchema = JSON.stringify(zodToJSONSchema(checkBackLater!.schema))
    expect(modelSchema).toContain('"type":"object"')
    for (const action of ['create', 'list', 'get', 'update', 'cancel']) {
      expect(modelSchema).toContain(`\"${action}\"`)
    }
  })

  it('uses a stable default cron:add idempotency key across provider tool call retries', async () => {
    const requests: JSONObject[] = []
    const tools = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRPC: async (method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
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

    const result = await cron!.execute('call_first', params)
    await cron!.execute('call_retry', params)

    expect(requests).toHaveLength(2)
    expect(requests[0]!.idempotency_key).toBe(requests[1]!.idempotency_key)
    expect(String(requests[0]!.idempotency_key).startsWith('cron:add:00000000-0000-0000-0000-000000000123:')).toBe(true)
    expect(result.presentation).toEqual([
      {
        kind: 'effect.receipt',
        payload: {
          operation_id: 'call_first',
          phase: 'confirmed',
          summary: '已创建定期任务',
          target: 'market-open-check',
          scope: '每 1 天',
          follow_up: '常规成功时保持安静，异常或变化会通知'
        }
      }
    ])
  })

  it('keeps explicit cron:add idempotency keys unchanged', async () => {
    const requests: JSONObject[] = []
    const cron = createScheduleTools({
      turnStart: turnStartForScheduleTool(),
      requestScheduleRPC: async (_method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
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
    const requests: JSONObject[] = []
    const cron = createScheduleTools({
      turnStart: turnStartForScheduleTool({ cronOrigin: true }),
      requestScheduleRPC: async (_method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
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
    const calls: Array<{ method: ScheduleRPCMethod; request: JSONObject }> = []
    const cron = createScheduleTools({
      turnStart: turnStartForScheduleTool({ cronOrigin: true }),
      requestScheduleRPC: async (method: ScheduleRPCMethod, request: JSONObject): Promise<JSONObject> => {
        calls.push({ method, request })
        return { status: 'ok', runs: [] }
      }
    }).find(tool => tool.name === 'cron')

    const result = await cron!.execute('call_cron_origin_runs', {
      action: 'runs',
      cron_schedule_id: '00000000-0000-0000-0000-000000000999'
    })

    expect(calls).toHaveLength(1)
    expect(calls[0]!.method).toBe(rpcMethods.scheduleCronRuns)
    expect(calls[0]!.request.cron_schedule_id).toBe('00000000-0000-0000-0000-000000000999')
    expect(result.presentation).toEqual([])
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
