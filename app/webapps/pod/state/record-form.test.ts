import { describe, expect, test } from 'bun:test'
import type { RecordData } from '@ankole/applet-sdk/types'
import { RecordFormModel } from './record-form'

const name = 'name'

describe('record form submissions', () => {
  test('a response waits for every attachment upload before capturing its values', async () => {
    const model = new RecordFormModel()
    const sent: RecordData[] = []
    const create = async (data: RecordData) => {
      sent.push(data)
    }
    model.change(name, 'With attachments')
    model.upload('first', true)
    model.upload('second', true)
    await model.submit(create)
    expect(sent).toEqual([])
    model.change('first', ['first-file'])
    model.upload('first', false)
    await model.submit(create)
    expect(sent).toEqual([])
    model.change('second', ['second-file'])
    model.upload('second', false)
    await model.submit(create)
    expect(sent).toEqual([{ name: 'With attachments', first: ['first-file'], second: ['second-file'] }])
  })

  test('one pending request owns a stable snapshot and only its success resets the fields', async () => {
    const model = new RecordFormModel()
    const request = Promise.withResolvers<void>()
    const sent: RecordData[] = []
    const create = (data: RecordData) => {
      sent.push(data)
      return request.promise
    }
    model.change(name, 'First response')
    const submission = model.submit(create)
    const duplicate = model.submit(create)
    model.change(name, 'Input during submission')
    expect(model.pending.value).toBe(true)
    expect(sent).toEqual([{ name: 'First response' }])
    expect(model.values.value).toEqual({ name: 'First response' })
    request.resolve()
    await Promise.all([submission, duplicate])
    expect(model.values.value).toEqual({})
    expect(model.generation.value).toBe(1)
    model.change(name, 'Second response')
    expect(model.generation.value).toBe(1)
    expect(model.values.value).toEqual({ name: 'Second response' })
    await model.submit(async data => {
      sent.push(data)
    })
    expect(sent.at(-1)).toEqual({ name: 'Second response' })
    expect(model.generation.value).toBe(2)
    expect(model.values.value).toEqual({})
  })

  test('a failed submission retains all values for an explicit retry', async () => {
    const model = new RecordFormModel()
    const failure = new Error('Connection lost')
    model.change(name, 'Keep this response')
    model.change('checked', false)
    await model.submit(async () => {
      throw failure
    })
    expect(model.error.value).toBe(failure)
    expect(model.values.value).toEqual({ name: 'Keep this response', checked: false })
    expect(model.generation.value).toBe(0)
    expect(model.pending.value).toBe(false)
    const sent: RecordData[] = []
    await model.submit(async data => {
      sent.push(data)
    })
    expect(sent).toEqual([{ name: 'Keep this response', checked: false }])
    expect(model.error.value).toBeUndefined()
  })
})
