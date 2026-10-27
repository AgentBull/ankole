import { expect, test } from 'bun:test'
import { MutationObserver, QueryClient } from '@tanstack/react-query'
import type { RequestSetupEmailOtpResponse } from '../../common/api/generated/types.gen'
import { EmailAdminModel } from './email-admin-model'

test('a pending or failed resend keeps the current verification step and entered code', async () => {
  const model = new EmailAdminModel()
  const client = new QueryClient()
  let delivery = Promise.withResolvers<RequestSetupEmailOtpResponse>()
  const send = new MutationObserver(client, {
    mutationFn: () => delivery.promise,
    onSuccess: model.receiveChallenge
  })
  const first = { challengeID: 'first' }
  const requested = send.mutate()
  delivery.resolve(first)
  await requested
  model.code.value = '123456'

  delivery = Promise.withResolvers<RequestSetupEmailOtpResponse>()
  const resend = send.mutate()
  expect(send.getCurrentResult().isPending).toBe(true)
  expect(send.getCurrentResult().data).toBeUndefined()
  expect(model.challenge.value).toEqual(first)
  expect(model.code.value).toBe('123456')

  delivery.reject(new Error('SMTP unavailable'))
  await expect(resend).rejects.toThrow('SMTP unavailable')
  expect(send.getCurrentResult().isError).toBe(true)
  expect(model.challenge.value).toEqual(first)
  expect(model.code.value).toBe('123456')

  delivery = Promise.withResolvers<RequestSetupEmailOtpResponse>()
  const retry = send.mutate()
  const replacement = { challengeID: 'replacement' }
  delivery.resolve(replacement)
  await retry
  expect(model.challenge.value).toEqual(replacement)
  expect(model.code.value).toBe('')

  model.server.value = 'smtp.example.com'
  model.editMail()
  expect(model.challenge.value).toBeUndefined()
  expect(model.server.value).toBe('smtp.example.com')
  client.clear()
  model[Symbol.dispose]()
})
