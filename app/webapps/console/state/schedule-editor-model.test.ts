import { describe, expect, test } from 'bun:test'
import {
  deliveryTargetDrafts,
  isMutableCronStatus,
  scheduleOccurrenceBound,
  ScheduleEditorModel,
  type ScheduleEditorDraft
} from './schedule-editor-model'

const draft: ScheduleEditorDraft = {
  ownerSessionId: 'lark:chat:market',
  bindingName: 'lark-agent',
  name: 'market-open',
  status: 'active',
  scheduleKind: 'cron',
  cronExpression: '30 8 * * 1',
  everyMs: '',
  anchorAt: '',
  timezone: 'Asia/Shanghai',
  deliveryTargets: [{ bindingName: 'lark-agent', channelId: 'lark:market', threadId: '' }],
  task: 'prepare report',
  payload: '{"task":"prepare report"}',
  hasAutomationJob: false,
  idempotencyKey: 'cron:add:market-open'
}

describe('ScheduleEditorModel', () => {
  test('requires a name, owner conversation, and task when it creates a recurring schedule', () => {
    const model = new ScheduleEditorModel()
    model.initialize('new', { ...draft, name: '' })

    expect(model.isComplete()).toBe(false)
    expect(model.toCreateBody()).toBeNull()

    model.name.value = 'market-open'
    model.payload.value = '{'
    expect(model.toCreateBody()).toBeNull()
    model.payload.value = draft.payload

    model.ownerSessionId.value = ''
    expect(model.toCreateBody()).toBeNull()
    model.ownerSessionId.value = draft.ownerSessionId

    model.task.value = ' '
    expect(model.isComplete()).toBe(false)
    expect(model.toCreateBody()).toBeNull()
    model.task.value = draft.task

    expect(model.isComplete()).toBe(true)
    expect(model.toCreateBody()).toEqual({
      owner_session_id: 'lark:chat:market',
      binding_name: 'lark-agent',
      name: 'market-open',
      status: 'active',
      schedule: {
        kind: 'cron',
        expression: '30 8 * * 1',
        timezone: 'Asia/Shanghai'
      },
      timezone: 'Asia/Shanghai',
      payload: { task: 'prepare report' },
      delivery: {
        targets: [{ binding_name: 'lark-agent', signal_channel_id: 'lark:market' }]
      },
      idempotency_key: 'cron:add:market-open'
    })

    model[Symbol.dispose]()
  })

  test('accepts an empty task when an automation job consumes the trigger', () => {
    const model = new ScheduleEditorModel()
    model.initialize('new', { ...draft, task: '', payload: '{}', hasAutomationJob: true })

    expect(model.isComplete()).toBe(true)
    expect(model.toCreateBody()?.payload).toEqual({})

    model[Symbol.dispose]()
  })

  test('reports dirty only after a loaded draft changes, including fields the update body ignores', () => {
    const model = new ScheduleEditorModel()
    expect(model.dirty.value).toBe(false)

    model.initialize('cron:market-open', { ...draft, deliveryTargets: [] })
    expect(model.dirty.value).toBe(false)

    model.ownerSessionId.value = 'lark:chat:other'
    expect(model.dirty.value).toBe(true)

    model.ownerSessionId.value = draft.ownerSessionId
    expect(model.dirty.value).toBe(false)

    model[Symbol.dispose]()
  })

  test('sends only fields that changed when it updates a recurring schedule', () => {
    const model = new ScheduleEditorModel()
    model.initialize('cron:market-open', draft)

    expect(model.toUpdateBody()).toEqual({})

    model.name.value = 'market-open-report'
    model.task.value = 'prepare updated report'

    expect(model.toUpdateBody()).toEqual({
      name: 'market-open-report',
      payload: { task: 'prepare updated report' }
    })

    model[Symbol.dispose]()
  })

  test('preserves a finite occurrence bound when schedule timing changes', () => {
    const model = new ScheduleEditorModel()
    model.initialize('cron:bounded', { ...draft, occurrences: { count: 5 } })

    model.cronExpression.value = '0 9 * * 1'

    expect(model.toUpdateBody()).toEqual({
      schedule: {
        kind: 'cron',
        expression: '0 9 * * 1',
        timezone: 'Asia/Shanghai',
        occurrences: { count: 5 }
      }
    })

    model[Symbol.dispose]()
  })

  test('reads both supported occurrence bounds and keeps terminal statuses immutable', () => {
    expect(scheduleOccurrenceBound({ occurrences: { count: 3 } })).toEqual({ count: 3 })
    expect(scheduleOccurrenceBound({ occurrences: { until: '2026-08-31T00:00:00Z' } })).toEqual({
      until: '2026-08-31T00:00:00Z'
    })
    expect(scheduleOccurrenceBound({ occurrences: { count: 0 } })).toBeUndefined()

    expect(isMutableCronStatus('active')).toBe(true)
    expect(isMutableCronStatus('paused')).toBe(true)
    expect(isMutableCronStatus('completed')).toBe(false)
    expect(isMutableCronStatus('deleted')).toBe(false)
  })

  test('sends target-only updates while the control plane preserves quiet success', () => {
    const model = new ScheduleEditorModel()
    model.initialize('cron:market-open', draft)

    model.addDeliveryTarget()
    model.updateDeliveryTarget(1, {
      bindingName: 'lark-secondary',
      channelId: 'lark:research',
      threadId: 'morning-report'
    })

    expect(model.toUpdateBody()).toEqual({
      delivery: {
        targets: [
          { binding_name: 'lark-agent', signal_channel_id: 'lark:market' },
          {
            binding_name: 'lark-secondary',
            signal_channel_id: 'lark:research',
            provider_thread_id: 'morning-report'
          }
        ]
      }
    })

    model.setBindingName('changed-execution-binding')
    expect(model.deliveryTargets.value[0]?.bindingName).toBe('changed-execution-binding')

    model.updateDeliveryTarget(1, {
      bindingName: 'changed-execution-binding',
      channelId: 'lark:market',
      threadId: ''
    })
    model.updateDeliveryTarget(0, { channelId: 'lark:market', threadId: '' })
    expect(model.isComplete()).toBe(false)
    expect(model.toUpdateBody()).toBeNull()

    model[Symbol.dispose]()
  })

  test('keeps non-task payload keys when the task text changes', () => {
    const model = new ScheduleEditorModel()
    model.initialize('cron:market-open', {
      ...draft,
      payload: '{"task":"prepare report","scope":"a-share"}'
    })

    model.task.value = 'prepare updated report'

    expect(model.toUpdateBody()).toEqual({
      payload: { task: 'prepare updated report', scope: 'a-share' }
    })

    model[Symbol.dispose]()
  })

  test('maps stored delivery targets', () => {
    expect(deliveryTargetDrafts({ targets: [{ binding_name: 'a', signal_channel_id: 'c' }] })).toEqual([
      { bindingName: 'a', channelId: 'c', threadId: '' }
    ])
    expect(deliveryTargetDrafts(undefined)).toEqual([])
  })

  test('requires an anchor for interval schedules and drops the hidden timezone', () => {
    const model = new ScheduleEditorModel()
    model.initialize('new', { ...draft, scheduleKind: 'every', cronExpression: '', everyMs: '60000' })

    expect(model.toCreateBody()).toBeNull()

    model.anchorAt.value = '2026-08-12T00:00:00Z'
    const body = model.toCreateBody()
    expect(body?.schedule).toEqual({ kind: 'every', every_ms: 60_000, anchor_at: '2026-08-12T00:00:00Z' })
    expect(body?.timezone).toBeNull()

    model[Symbol.dispose]()
  })
})
