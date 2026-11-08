import { expect, spyOn, test } from 'bun:test'
import { QueryClient, QueryObserver } from '@tanstack/react-query'
import { createAppletRuns } from './applet-runs'
import * as sdk from './api/generated/sdk.gen'
import type { PodRealtime, TopicHandle } from './realtime'
import type { ActionRun } from '@ankole/applet-sdk/types'

const settle = () => new Promise(resolve => setTimeout(resolve, 0))

function fixture() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })
  const listeners = new Map<string, (event: unknown) => void>()
  let closed = false
  const handle: TopicHandle = {
    ready: Promise.resolve({}),
    on(event, callback) {
      listeners.set(event, callback)
      return () => listeners.delete(event)
    },
    presence: () => [],
    push: async () => {
      throw new Error('Run subscriptions only receive updates')
    },
    close() {
      closed = true
      listeners.clear()
    }
  }
  const realtime = { join: async () => handle } as unknown as PodRealtime
  const api = createAppletRuns(client, realtime, 'applet')
  const observer = new QueryObserver(client, {
    queryKey: api.key(1000),
    queryFn: ({ signal }) => api.get(1000, signal)
  })
  return {
    client,
    api,
    observer,
    listeners,
    get closed() {
      return closed
    }
  }
}

test('a committed progress event replaces an older read, and reconnection catches a missed completion', async () => {
  const context = fixture()
  let run: ActionRun = {
    id: 1000,
    automation_job_id: 1000,
    event: {},
    status: 'running',
    attempts: 1,
    slice_count: 0,
    progress: {},
    stdout_truncated: false,
    stderr_truncated: false
  }
  let first = true
  let aborted = false
  const read = async (options: Parameters<typeof sdk.podAppletRun>[0]) => {
    if (first) {
      first = false
      await new Promise((_resolve, reject) =>
        options.signal!.addEventListener(
          'abort',
          () => {
            aborted = true
            reject(options.signal!.reason)
          },
          { once: true }
        )
      )
    }
    return { run } as Awaited<ReturnType<typeof sdk.podAppletRun>>
  }
  const http = spyOn(sdk, 'podAppletRun').mockImplementation(read as typeof sdk.podAppletRun)
  const stop = context.observer.subscribe(() => {})
  const unsubscribe = context.api.subscribe(1000, () => {})
  try {
    await settle()
    expect(aborted).toBe(true)
    expect(context.observer.getCurrentResult().data?.status).toBe('running')
    run = { ...run, status: 'queued', progress: { rows: 40 }, slice_count: 1 }
    context.listeners.get('changed')!(run)
    await settle()
    expect(context.observer.getCurrentResult().data?.progress).toEqual({ rows: 40 })
    run = { ...run, status: 'succeeded', result: { rows: 100 } }
    context.listeners.get('rejoined')!({})
    await settle()
    expect(context.observer.getCurrentResult().data?.result).toEqual({ rows: 100 })
    expect(context.observer.getCurrentResult().data?.status).toBe('succeeded')
    expect(http).toHaveBeenCalledTimes(4)
  } finally {
    unsubscribe()
    stop()
    http.mockRestore()
    context.client.clear()
  }
  expect(context.closed).toBe(true)
})

test('ActionRun reads and live updates preserve business JSON strings verbatim without rewriting Pod file paths', async () => {
  const pageID = '019a2b00-0000-7000-8000-000000000033'
  const rawPreviewPath = `/api/v2/pod/pages/${pageID}/files/content?path=assets%2Fpreview%2Fstep1.png`
  const rawFinalPath = `/api/v2/pod/pages/${pageID}/files/content?path=assets%2Ffinal%2Fposter.png`
  const context = fixture()
  let run: ActionRun = {
    id: 1000,
    automation_job_id: 1000,
    event: {},
    status: 'running',
    attempts: 1,
    slice_count: 0,
    progress: {
      previewUrl: rawPreviewPath
    },
    stdout_truncated: false,
    stderr_truncated: false
  }
  const http = spyOn(sdk, 'podAppletRun').mockImplementation((async () => ({
    run
  })) as unknown as typeof sdk.podAppletRun)
  const stop = context.observer.subscribe(() => {})
  const unsubscribe = context.api.subscribe(1000, () => {})
  try {
    await settle()
    expect(context.observer.getCurrentResult().data?.progress).toEqual({
      previewUrl: rawPreviewPath
    })

    run = {
      ...run,
      status: 'succeeded',
      result: {
        original: rawFinalPath,
        file: { path: `pages/${pageID}/assets/final/poster.png` }
      }
    }
    context.listeners.get('changed')!(run)
    await settle()
    expect(context.observer.getCurrentResult().data?.result).toEqual({
      original: rawFinalPath,
      file: { path: `pages/${pageID}/assets/final/poster.png` }
    })
  } finally {
    unsubscribe()
    stop()
    http.mockRestore()
    context.client.clear()
  }
})

test('revoked Run access clears the cached result and closes its live subscription', async () => {
  const context = fixture()
  const run: ActionRun = {
    id: 1000,
    automation_job_id: 1000,
    event: {},
    status: 'succeeded',
    attempts: 1,
    slice_count: 0,
    progress: {},
    stdout_truncated: false,
    stderr_truncated: false,
    result: { private: true }
  }
  const http = spyOn(sdk, 'podAppletRun').mockResolvedValue({ run } as Awaited<ReturnType<typeof sdk.podAppletRun>>)
  let revoked = false
  const stop = context.observer.subscribe(() => {})
  const unsubscribe = context.api.subscribe(1000, event => {
    revoked = !!event.access_revoked
  })
  try {
    await settle()
    expect(context.client.getQueryData(context.api.key(1000))).toEqual(run)
    context.listeners.get('access_revoked')!({})
    expect(revoked).toBe(true)
    expect(context.closed).toBe(true)
    expect(context.client.getQueryData(context.api.key(1000))).toBeUndefined()
  } finally {
    unsubscribe()
    stop()
    http.mockRestore()
    context.client.clear()
  }
})
