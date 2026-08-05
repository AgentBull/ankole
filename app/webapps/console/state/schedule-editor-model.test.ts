import { describe, expect, test } from 'bun:test'
import { ScheduleEditorModel, type ScheduleEditorDraft } from './schedule-editor-model'

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
  deliveryChannelId: 'lark:market',
  deliveryThreadId: '',
  payload: '{"task":"prepare report"}',
  idempotencyKey: 'cron:add:market-open'
}

describe('ScheduleEditorModel', () => {
  test('requires a name and an owning session when it creates a recurring schedule', () => {
    const model = new ScheduleEditorModel()
    model.initialize('new', { ...draft, name: '' })

    expect(model.isComplete()).toBe(false)
    expect(model.toCreateBody()).toBeNull()

    model.name.value = 'market-open'
    model.payload.value = '{'
    expect(model.toCreateBody()).toBeNull()
    model.payload.value = draft.payload

    model.sessionId.value = ''
    expect(model.toCreateBody()).toBeNull()
    model.sessionId.value = draft.sessionId

    expect(model.isComplete()).toBe(true)
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
      payload: { task: 'prepare report' },
      delivery: { signal_channel_id: 'lark:market' },
      idempotency_key: 'cron:add:market-open'
    })

    model[Symbol.dispose]()
  })

  test('sends only fields that changed when it updates a recurring schedule', () => {
    const model = new ScheduleEditorModel()
    model.initialize('cron:market-open', draft)

    expect(model.toUpdateBody()).toEqual({})

    model.name.value = 'market-open-report'
    model.payload.value = '{"task":"prepare updated report"}'

    expect(model.toUpdateBody()).toEqual({
      name: 'market-open-report',
      payload: { task: 'prepare updated report' }
    })

    model[Symbol.dispose]()
  })
})
