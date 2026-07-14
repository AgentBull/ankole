import { describe, expect, test } from 'bun:test'
import { requestErrorMessage } from './request-errors'

describe('requestErrorMessage', () => {
  test('drops server debug sections that may contain request headers or cookies', () => {
    const error = new Error(
      '# Plug.InvalidRequest at POST /oauth/token\n\nException:\nstack line\n\n## Request headers\ncookie: secret'
    )
    expect(requestErrorMessage(error)).toBe('# Plug.InvalidRequest at POST /oauth/token')
  })

  test('bounds unstructured messages before rendering them in the UI', () => {
    expect(requestErrorMessage(new Error('x'.repeat(600)))).toBe(`${'x'.repeat(500)}…`)
  })
})
