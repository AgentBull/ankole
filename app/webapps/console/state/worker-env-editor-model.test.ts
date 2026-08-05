import { describe, expect, test } from 'bun:test'
import { WorkerEnvEditorModel } from './worker-env-editor-model'

describe('WorkerEnvEditorModel', () => {
  test('only reloads the same variable after an explicit reset', () => {
    const model = new WorkerEnvEditorModel()

    model.initialize('worker-env:NPM_TOKEN', { name: 'NPM_TOKEN', value: 'one', secret: true, description: '' })
    expect(model.dirty.value).toBe(false)
    model.value.value = 'edited'
    expect(model.dirty.value).toBe(true)
    model.initialize('worker-env:NPM_TOKEN', { name: 'NPM_TOKEN', value: 'two', secret: true, description: '' })
    expect(model.value.value).toBe('edited')
    expect(model.secret.value).toBe(true)

    model.resetSource()
    model.initialize('worker-env:NPM_TOKEN', { name: 'NPM_TOKEN', value: 'two', secret: false, description: 'ci' })
    expect(model.value.value).toBe('two')
    expect(model.secret.value).toBe(false)
    expect(model.description.value).toBe('ci')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })
})
