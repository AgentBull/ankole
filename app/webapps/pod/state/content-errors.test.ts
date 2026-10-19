import { beforeAll, expect, test } from 'bun:test'
import i18n, { loadLocale } from '../../common/i18n'
import { InternalAPIError } from '../../common/internal-api-client'
import { contentError } from '../content-errors'
import { RealtimeRequestError } from '../realtime'

beforeAll(() => loadLocale('en-US'))

test('Pod protocol failures have localized recovery instructions without changing their original status or details', () => {
  const payload = { error: { code: 'field_conflict', message: 'field_conflict', details: { field_id: 'amount' } } }
  const error = new InternalAPIError(409, 'Conflict', payload)
  const originalMessage = error.message
  expect((contentError(error) as Error).message).toBe(i18n.t('pod.errors.field_conflict'))
  expect((contentError(new RealtimeRequestError({ reason: 'not_found' })) as Error).message).toBe(
    i18n.t('pod.errors.not_found')
  )
  expect(error.status).toBe(409)
  expect(error.payload).toBe(payload)
  expect(error.message).toBe(originalMessage)
})

test('ordinary client failures and unknown protocol errors retain their useful original identity', () => {
  const client = new Error('Network unavailable')
  const extension = new InternalAPIError(422, 'Validation', {
    error: { code: 'extension_specific', message: 'Choose a product first' }
  })
  expect(contentError(client)).toBe(client)
  expect(contentError(extension)).toBe(extension)
})
