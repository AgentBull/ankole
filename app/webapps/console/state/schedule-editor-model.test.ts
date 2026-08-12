import { describe, expect, test } from 'bun:test'
import { deliveryTargetDrafts, ScheduleEditorModel, type ScheduleEditorDraft } from './schedule-editor-model'

const draft: ScheduleEditorDraft = {
  sessionId: 'lark:chat:market',
  bindingName: 'lark-agent',
  name: 'market-open',
  status: 'active',
  scheduleKind: 'cron',
  cronExpression: '30 8 * * 1',
  everyMs: '',
  anchorAt: '',
  timezone: 'Asia/Shanghai',
  deliveryTargets: [{ bindingName: 'lark-agent', channelId: 'lark:market', threadId: '' }],
  idempotencyKey: 'cron:add:market-open'
}

describe('ScheduleEditorModel', () => {
  test('requires a name and an owning session when it creates a recurring schedule', () => {
    const model = new ScheduleEditorModel()
    model.initialize('new', { ...draft, name: '' })

    expect(model.toCreateBody()).toBeNull()

    model.name.value = 'market-open'
    model.sessionId.value = ''
    expect(model.toCreateBody()).toBeNull()
    model.sessionId.value = draft.sessionId

    expect(model.toCreateBody()).toEqual({
      session_id: 'lark:chat:market',
      binding_name: 'lark-agent',
      name: 'market-open',
      status: 'active',
      schedule: {
        kind: 'cron',
        expression: '30 8 * * 1',
        timezone: 'Asia/Shanghai'
      },
      timezone: 'Asia/Shanghai',
      delivery: {
        targets: [{ binding_name: 'lark-agent', signal_channel_id: 'lark:market' }]
      },
      idempotency_key: 'cron:add:market-open'
    })

    model[Symbol.dispose]()
  })

  test('sends only fields that changed when it updates a recurring schedule', () => {
    const model = new ScheduleEditorModel()
    model.initialize('cron:market-open', draft)

    expect(model.toUpdateBody()).toEqual({})

    model.name.value = 'market-open-report'

    expect(model.toUpdateBody()).toEqual({ name: 'market-open-report' })

    model[Symbol.dispose]()
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
    expect(model.toUpdateBody()).toBeNull()

    model[Symbol.dispose]()
  })

  test('maps the legacy single-target delivery and keeps the schedule editable', () => {
    expect(
      deliveryTargetDrafts({ signal_channel_id: 'lark:market', provider_thread_id: 'thread-1' }, 'lark-agent')
    ).toEqual([{ bindingName: 'lark-agent', channelId: 'lark:market', threadId: 'thread-1' }])
    expect(deliveryTargetDrafts({ targets: [{ binding_name: 'a', signal_channel_id: 'c' }] }, 'a')).toEqual([
      { bindingName: 'a', channelId: 'c', threadId: '' }
    ])
    expect(deliveryTargetDrafts(undefined, 'a')).toEqual([])

    const model = new ScheduleEditorModel()
    model.initialize('cron:legacy', {
      ...draft,
      deliveryTargets: deliveryTargetDrafts({ signal_channel_id: 'lark:market' }, 'lark-agent')
    })

    expect(model.toUpdateBody()).toEqual({})
    model.name.value = 'renamed'
    expect(model.toUpdateBody()).toEqual({ name: 'renamed' })

    model[Symbol.dispose]()
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
