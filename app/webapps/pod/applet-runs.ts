import type { RunsAPI } from '@ankole/applet-sdk/types'
import type { QueryClient } from '@tanstack/react-query'
import { podAppletRun } from './api/generated/sdk.gen'
import { contentKeys } from './content-api'
import { isRealtimeAccessDenied, type PodRealtime, type TopicHandle } from './realtime'

/** Run snapshots use the host's query cache and authenticated, shared socket. */
export function createAppletRuns(client: QueryClient, realtime: PodRealtime, pageID: string): RunsAPI {
  const key = (runID: number) => [...contentKeys.page(pageID), 'run', runID]
  return {
    key,
    async get(runID, signal) {
      const { run } = await podAppletRun({ path: { page_id: pageID, id: runID }, signal })
      return run
    },
    subscribe(runID, callback) {
      let closed = false
      let handle: TopicHandle | undefined
      let retry: ReturnType<typeof setTimeout> | undefined
      const query = { queryKey: key(runID), exact: true }
      const close = () => {
        closed = true
        clearTimeout(retry)
        handle?.close()
      }
      const refresh = async () => {
        if (closed) return
        // Cancel even the initial read so an older HTTP response cannot hide a committed update.
        await client.cancelQueries(query)
        if (!closed) await client.invalidateQueries(query)
      }
      const revoke = () => {
        if (closed) return
        close()
        client.removeQueries(query)
        callback({ access_revoked: true })
      }
      const failed = (error: unknown) => {
        if (isRealtimeAccessDenied(error)) revoke()
      }
      const connect = () => {
        void realtime.join(`run:${runID}`).then(
          joined => {
            if (closed) return joined.close()
            handle = joined
            handle.on('changed', refresh)
            handle.on('rejoined', refresh)
            handle.on('access_revoked', revoke)
            void handle.ready.then(refresh, failed)
          },
          error => {
            failed(error)
            if (!closed) retry = setTimeout(connect, 1000)
          }
        )
      }
      connect()
      return close
    }
  }
}
