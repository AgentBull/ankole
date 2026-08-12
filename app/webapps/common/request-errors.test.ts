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

  test('reads the console API error envelope', () => {
    expect(requestErrorMessage({ error: { message: 'Schedule not found' } })).toBe('Schedule not found')
    expect(requestErrorMessage({ error: 'not_editable' })).toBe('not_editable')
  })

  test('reads the Phoenix default error envelope', () => {
    expect(requestErrorMessage({ errors: { detail: 'Internal Server Error' } })).toBe('Internal Server Error')
  })

  test('serializes unrecognized object bodies instead of "[object Object]"', () => {
    expect(requestErrorMessage({ status: 502, reason: 'bad gateway' })).toBe('{"status":502,"reason":"bad gateway"}')
  })

  test('passes raw text bodies through', () => {
    expect(requestErrorMessage('upstream connect error')).toBe('upstream connect error')
  })
})
