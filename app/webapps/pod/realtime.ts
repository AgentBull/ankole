import { uuidV4 } from '@agentbull/active-support'
import { t } from 'i18next'
import { Presence, Socket, type Channel, type Push } from 'phoenix'
import type { EphemeralChannel, PresenceMember } from '@ankole/applet-sdk/types'
import { identityQuery } from './content-api'
import { podRealtimeToken, podVersions } from './api/generated/sdk.gen'
import { InternalAPIError } from '../common/internal-api-client'

type Topic = {
  channel: Channel
  ready: Promise<unknown>
  references: number
  presence?: Presence
  presenceListeners?: Set<() => void>
}
export type TopicHandle = {
  ready: Promise<unknown>
  push<T>(event: string, payload: object): Promise<T>
  on(event: string, callback: (payload: any) => void): () => void
  close(): void
}

export class RealtimeRequestError extends Error {
  constructor(readonly payload: unknown) {
    super(
      payload && typeof payload === 'object' && 'reason' in payload
        ? String(payload.reason)
        : t('pod.content.the_realtime_request_was_rejected')
    )
  }
}

export function isRealtimeAccessDenied(error: unknown): boolean {
  return (
    (error instanceof RealtimeRequestError &&
      ['not_found', 'forbidden'].includes(String((error.payload as { reason?: string })?.reason))) ||
    (error instanceof InternalAPIError && [401, 403, 404].includes(error.status))
  )
}

const pushResult = <T>(push: Push) =>
  new Promise<T>((resolve, reject) => {
    push
      .receive('ok', resolve)
      .receive('error', payload => reject(new RealtimeRequestError(payload)))
      .receive('timeout', () => reject(new Error(t('pod.content.the_realtime_connection_timed_out_try_again_later'))))
  })

/** A browser tab owns one authenticated socket. Topic handles own their subscriptions. */
export class PodRealtime {
  private socket?: Socket
  private connecting?: Promise<Socket>
  private token = ''
  private topics = new Map<string, Topic>()
  private disposed = false
  private versions = new Map<
    string,
    { kind: 'pages' | 'tables'; id: string; changed(version: number | undefined): void }
  >()
  private verifyTimer?: ReturnType<typeof setInterval>
  private visible = () => {
    if (document.visibilityState === 'visible') void this.verify()
  }
  principal?: { uid: string; name?: string }

  private connect(): Promise<Socket> {
    if (this.disposed) return Promise.reject(new Error(t('pod.content.the_realtime_connection_is_closed')))
    if (this.socket) return Promise.resolve(this.socket)
    if (this.connecting) return this.connecting
    this.connecting = podRealtimeToken()
      .then(result => {
        if (this.disposed) throw new Error(t('pod.content.the_realtime_connection_is_closed'))
        this.token = result.token
        this.principal = result.principal
        const socket = new Socket('/pod/socket', { params: () => ({ token: this.token, ...identityQuery() }) })
        socket.onOpen(() => {
          void this.verify()
        })
        socket.onError(() => {
          void podRealtimeToken()
            .then(result => {
              this.token = result.token
            })
            .catch(() => {})
        })
        socket.connect()
        this.socket = socket
        return socket
      })
      .finally(() => {
        this.connecting = undefined
      })
    return this.connecting
  }

  async join(name: string): Promise<TopicHandle> {
    const socket = await this.connect()
    let topic = this.topics.get(name)
    if (!topic) {
      const channel = socket.channel(name, {})
      const presence = name.startsWith('applet:') ? new Presence(channel) : undefined
      const presenceListeners = new Set<() => void>()
      presence?.onSync(() => {
        for (const listener of presenceListeners) listener()
      })
      const ready = pushResult(channel.join())
      topic = { channel, ready, references: 0, presence, presenceListeners }
      this.topics.set(name, topic)
      // A failed join must be observed even if its owner is unmounted before ready.
      void ready.catch(() => {})
    }
    const owned = topic
    owned.references++
    let closed = false
    const bindings: [string, number][] = []
    return {
      ready: owned.ready,
      push: async <T>(event: string, payload: object) => {
        await owned.ready
        if (closed) throw new Error(t('pod.content.the_page_connection_is_closed'))
        return pushResult<T>(owned.channel.push(event, payload))
      },
      on: (event, callback) => {
        const ref = owned.channel.on(event, callback)
        bindings.push([event, ref])
        return () => owned.channel.off(event, ref)
      },
      close: () => {
        if (closed) return
        closed = true
        for (const [event, ref] of bindings) owned.channel.off(event, ref)
        if (--owned.references === 0) {
          owned.channel.leave()
          this.topics.delete(name)
        }
      }
    }
  }

  watchVersion(kind: 'pages' | 'tables', id: string, changed: (version: number | undefined) => void) {
    const key = `${kind}:${id}:${uuidV4()}`
    this.versions.set(key, { kind, id, changed })
    if (!this.verifyTimer) {
      this.verifyTimer = setInterval(() => {
        void this.verify()
      }, 60000)
      document.addEventListener('visibilitychange', this.visible)
    }
    return () => {
      this.versions.delete(key)
      if (!this.versions.size) {
        clearInterval(this.verifyTimer)
        this.verifyTimer = undefined
        document.removeEventListener('visibilitychange', this.visible)
      }
    }
  }

  private async verify() {
    if (!this.versions.size || this.disposed) return
    const watched = [...this.versions.values()]
    try {
      const versions = await podVersions({
        body: {
          data: {
            pages: [...new Set(watched.filter(item => item.kind === 'pages').map(item => item.id))],
            tables: [...new Set(watched.filter(item => item.kind === 'tables').map(item => item.id))]
          }
        }
      })
      for (const item of watched) {
        const version =
          item.kind === 'pages'
            ? versions.pages.find(page => page.id === item.id)?.revision
            : versions.tables.find(table => table.id === item.id)?.data_version
        // Also notify unchanged versions: formulas with time functions can change without writes.
        item.changed(version)
      }
    } catch {
      /* Keep drafts and cached data during a temporary network failure. */
    }
  }

  channel(pageID: string, room: string): EphemeralChannel {
    if (!room || room.length > 120) throw new Error(t('pod.content.channel_names_must_be_between_1_and_120_characters'))
    let handle: TopicHandle | undefined,
      closed = false
    let detachPresence: (() => void) | undefined
    let members: PresenceMember[] = []
    const listeners = new Set<() => void>()
    const events = new Map<string, Set<(payload: unknown) => void>>()
    const joined = this.join(`applet:${pageID}:${room}`).then(async value => {
      handle = value
      if (closed) {
        value.close()
        return value
      }
      await value.ready
      const topic = this.topics.get(`applet:${pageID}:${room}`)!
      const syncPresence = () => {
        if (closed) return
        const presence = topic.presence!
        members = presence.list((id, data) => ({ id, ...data.metas[0] }))
        for (const notify of listeners) notify()
      }
      topic.presenceListeners!.add(syncPresence)
      detachPresence = () => {
        topic.presenceListeners!.delete(syncPresence)
      }
      syncPresence()
      value.on('broadcast', ({ event, payload }) => {
        for (const callback of events.get(event) ?? []) callback(payload)
      })
      value.on('access_revoked', () => {
        members = []
        for (const notify of listeners) notify()
        value.close()
      })
      return value
    })
    void joined.catch(() => {})
    return {
      broadcast: async (event, payload) => {
        const value = await joined
        await value.push('broadcast', { event, payload })
      },
      on: (event, callback) => {
        const callbacks = events.get(event) ?? new Set()
        callbacks.add(callback)
        events.set(event, callbacks)
        return () => {
          callbacks.delete(callback)
        }
      },
      presence: () => members,
      subscribe: callback => {
        listeners.add(callback)
        return () => {
          listeners.delete(callback)
        }
      },
      close: () => {
        closed = true
        detachPresence?.()
        handle?.close()
        events.clear()
        listeners.clear()
      }
    }
  }

  dispose() {
    this.disposed = true
    clearInterval(this.verifyTimer)
    document.removeEventListener('visibilitychange', this.visible)
    this.versions.clear()
    for (const topic of this.topics.values()) topic.channel.leave()
    this.topics.clear()
    this.socket?.disconnect()
    this.socket = undefined
  }
}
