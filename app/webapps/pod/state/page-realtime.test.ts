import { afterEach, beforeAll, expect, jest, test } from 'bun:test'
import { QueryClient } from '@tanstack/react-query'
import i18n, { loadLocale } from '../../common/i18n'
import type { TopicHandle } from '../realtime'
import { watchPageRealtime } from '../use-page-realtime'

beforeAll(() => loadLocale('en-US'))
afterEach(() => jest.useRealTimers())

/** A page topic whose join settles only when the test settles it. */
function pageTopic() {
  let settle!: { resolve(value?: unknown): void; reject(error: unknown): void }
  const ready = new Promise((resolve, reject) => (settle = { resolve, reject }))
  void ready.catch(() => {})
  const closed = jest.fn()
  const handle: TopicHandle = {
    ready,
    push: async () => undefined as never,
    on: () => () => {},
    presence: () => [],
    close: closed
  }
  let deliver!: (handle: TopicHandle) => void
  const delivered = new Promise<TopicHandle>(resolve => (deliver = resolve))
  let pending = false
  return {
    settle,
    closed,
    /** Keep join() pending, as while the realtime token request or the socket has not completed. */
    holdJoin() {
      pending = true
    },
    deliverHandle: () => deliver(handle),
    realtime: { join: () => (pending ? delivered : Promise.resolve(handle)), watchVersion: () => () => {} }
  }
}

async function watched(topic: ReturnType<typeof pageTopic>) {
  const page = { revoked: jest.fn(), failed: jest.fn() }
  const stop = watchPageRealtime(topic.realtime, new QueryClient(), 'page', 1, page)
  await Promise.resolve()
  return { page, stop }
}

test('a page join that stays pending offers a reconnection after 10 seconds and closes its topic', async () => {
  jest.useFakeTimers()
  const topic = pageTopic()
  const { page, stop } = await watched(topic)
  jest.advanceTimersByTime(9_999)
  expect(page.failed).not.toHaveBeenCalled()
  jest.advanceTimersByTime(1)
  expect(page.failed).toHaveBeenCalledWith(
    new Error(i18n.t('pod.content.the_realtime_connection_is_temporarily_unavailable_you_can_still_view'))
  )
  expect(page.revoked).not.toHaveBeenCalled()
  expect(topic.closed).toHaveBeenCalled()
  stop()
})

test('a page join that completes in time keeps its topic open', async () => {
  jest.useFakeTimers()
  const topic = pageTopic()
  const { page, stop } = await watched(topic)
  topic.settle.resolve()
  await Promise.resolve()
  jest.advanceTimersByTime(20_000)
  expect(page.failed).not.toHaveBeenCalled()
  expect(topic.closed).not.toHaveBeenCalled()
  stop()
})

test('a join that has no handle after 10 seconds offers a reconnection and closes the late handle', async () => {
  jest.useFakeTimers()
  const topic = pageTopic()
  topic.holdJoin()
  const { page, stop } = await watched(topic)
  jest.advanceTimersByTime(10_000)
  expect(page.failed).toHaveBeenCalledTimes(1)
  topic.deliverHandle()
  await Promise.resolve()
  await Promise.resolve()
  expect(topic.closed).toHaveBeenCalled()
  stop()
})
