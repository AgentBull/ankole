import { describe, expect, test } from 'bun:test'
import { CodexAccountEditorModel } from './codex-account-editor-model'

describe('CodexAccountEditorModel', () => {
  test('never initializes auth JSON from an edited account and clears it when the route source changes', () => {
    const model = new CodexAccountEditorModel()

    model.initialize('account:first', 'First')
    model.authJSON.value = '{"tokens":{"access_token":"secret"}}'
    model.initialize('account:first', 'Refetched First')

    expect(model.name.value).toBe('First')
    expect(model.authJSON.value).toContain('secret')

    model.initialize('account:second', 'Second')
    expect(model.name.value).toBe('Second')
    expect(model.authJSON.value).toBe('')
    model[Symbol.dispose]()
  })
})
