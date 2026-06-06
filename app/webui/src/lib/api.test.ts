import { describe, expect, it } from 'bun:test'
import { ApiError, apiErrorMessage } from './api'

describe('apiErrorMessage', () => {
  it('falls back to the ApiError message when the response body is empty', () => {
    expect(apiErrorMessage(new ApiError(500, null))).toBe('API request failed (500)')
  })

  it('uses server-provided JSON and plain-text error messages', () => {
    expect(apiErrorMessage(new ApiError(422, { error: 'channel name must not be empty' }))).toBe(
      'channel name must not be empty'
    )
    expect(apiErrorMessage(new ApiError(500, { error: { message: 'App config key is not registered' } }))).toBe(
      'App config key is not registered'
    )
    expect(apiErrorMessage(new ApiError(500, 'plain text failure'))).toBe('plain text failure')
  })
})
