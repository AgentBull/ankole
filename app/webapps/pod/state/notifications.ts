import { computed, signal } from '@preact/signals-react'
import { isDesktopRuntime } from '../../common/browser-context'
import { getPodWebPush, subscribePodWebPush, unsubscribePodWebPush } from '../api/generated/sdk.gen'
import type { podCommentAttention, podConversationAttention } from '../api/generated/sdk.gen'

type AttentionRoom = NonNullable<Awaited<ReturnType<typeof podConversationAttention>>>[number]
type CommentAttention = NonNullable<Awaited<ReturnType<typeof podCommentAttention>>>[number]

/** What the browser last knew about each room, so Pod notifies only about changes. */
export type RoomSnapshot = Map<string, { rowStatus: string; lastNotifiableSeq: number }>
export type PodNotification = { tag: string; title: string; body: string; url: string; decision: boolean }

const ownMessages = new Map<string, number>()
const ownChannel = typeof BroadcastChannel === 'function' ? new BroadcastChannel('ankole-own-messages') : undefined
const recordOwn = (roomID: string, seq: number) => ownMessages.set(roomID, Math.max(seq, ownMessages.get(roomID) ?? 0))
ownChannel?.addEventListener('message', (event: MessageEvent<{ roomID: string; seq: number }>) =>
  recordOwn(event.data.roomID, event.data.seq)
)

/** Every Pod tab of this browser learns the messages its Human sent, so none of them notifies about one. */
export function noteOwnMessage(roomID: string, seq: number) {
  recordOwn(roomID, seq)
  ownChannel?.postMessage({ roomID, seq })
}

export const ownMessageSeq = (roomID: string) => ownMessages.get(roomID) ?? 0

const OPT_OUT_KEY = 'ankole.notifications.off'
const PROMPT_KEY = 'ankole.notifications.prompt-dismissed'
const SERVICE_WORKER = '/pod/service-worker.js'

/** Chat counts unread IM rooms and pending decisions; Home counts Pages with unread comments. */
export function chatAttentionCount(rooms: readonly AttentionRoom[] | undefined): number {
  return (
    rooms?.filter(
      room =>
        room.rowStatus === 'waiting_choice' ||
        (room.conversationKind !== 'assistant_task' && room.rowStatus === 'unread')
    ).length ?? 0
  )
}

export function snapshotRooms(rooms: readonly AttentionRoom[]): RoomSnapshot {
  return new Map(rooms.map(room => [room.id, { rowStatus: room.rowStatus, lastNotifiableSeq: room.lastNotifiableSeq }]))
}

/**
 * A room notifies when it starts waiting on the Human's decision, or when a new notifiable message that the Human did
 * not send leaves an unmuted room unread. The second rule reads the watermarks rather than `rowStatus`, because a room
 * that is also working or waiting shows that status instead of `unread`; decisions stay in `waiting_choice` even when
 * the room is muted.
 */
export function roomNotifications(
  previous: RoomSnapshot,
  rooms: readonly AttentionRoom[],
  pathOf: (room: AttentionRoom) => string,
  untitled: string,
  ownSeq: (roomID: string) => number = () => 0
): PodNotification[] {
  const notifications: PodNotification[] = []
  for (const room of rooms) {
    const before = previous.get(room.id)
    const latest = room.lastNotifiableSeq
    const decision = room.rowStatus === 'waiting_choice' && before?.rowStatus !== 'waiting_choice'
    const message =
      !room.viewer.muted &&
      latest > room.viewer.lastReadSeq &&
      latest > (before?.lastNotifiableSeq ?? 0) &&
      latest > ownSeq(room.id)
    if (!decision && !message) continue
    const colleague = room.conversationKind === 'colleague_dm' ? room.agents[0] : undefined
    notifications.push({
      tag: room.id,
      title: colleague?.displayName ?? (room.title || untitled),
      body: room.latestMessagePreview ?? '',
      url: pathOf(room),
      decision
    })
  }
  return notifications
}

/** A Page notifies when its comment activity moves past what this browser last saw. */
export function commentNotifications(
  previous: Map<string, string>,
  rows: readonly CommentAttention[],
  pathOf: (row: CommentAttention) => string,
  body: string,
  untitled: string
): PodNotification[] {
  return rows
    .filter(row => (previous.get(row.page.id) ?? '') < row.activity_at)
    .map(row => ({
      tag: `comments:${row.page.id}`,
      title: row.page.title || untitled,
      body,
      url: pathOf(row),
      decision: false
    }))
}

function readFlag(key: string): boolean {
  try {
    return globalThis.localStorage?.getItem(key) === 'true'
  } catch {
    return false
  }
}

function writeFlag(key: string, value: boolean) {
  try {
    if (value) globalThis.localStorage?.setItem(key, 'true')
    else globalThis.localStorage?.removeItem(key)
  } catch {
    // A browser without storage keeps the choice for this page only.
  }
}

const supported = () => typeof globalThis.Notification === 'function'
const pushSupported = () =>
  !isDesktopRuntime() && 'serviceWorker' in navigator && 'PushManager' in globalThis && globalThis.isSecureContext

/** One browser's notification permission and the Human's choice to receive notifications on it. */
class BrowserNotifications {
  readonly permission = signal<NotificationPermission | 'unsupported'>(
    supported() ? globalThis.Notification.permission : 'unsupported'
  )
  readonly optedOut = signal(readFlag(OPT_OUT_KEY))
  readonly promptDismissed = signal(readFlag(PROMPT_KEY))
  /** This browser could not subscribe to Web Push, so notifications arrive only while Pod is open. */
  readonly pushFailed = signal(false)
  readonly enabled = computed(() => this.permission.value === 'granted' && !this.optedOut.value)
  /** Pod offers to turn notifications on only while the browser has not decided yet. */
  readonly shouldPrompt = computed(() => this.permission.value === 'default' && !this.promptDismissed.value)

  /** Asks for permission; browsers accept the request only from a click or key press. */
  async enable(): Promise<boolean> {
    if (!supported()) return false
    await globalThis.Notification.requestPermission()
    // The desktop app's notification shim answers with its own state names, so read the standard property.
    this.permission.value = globalThis.Notification.permission
    this.optedOut.value = false
    writeFlag(OPT_OUT_KEY, false)
    this.dismissPrompt()
    return this.enabled.value
  }

  async disable() {
    this.optedOut.value = true
    writeFlag(OPT_OUT_KEY, true)
    await this.syncPush().catch(() => {})
  }

  dismissPrompt() {
    this.promptDismissed.value = true
    writeFlag(PROMPT_KEY, true)
  }

  /** Points this browser's push subscription at the signed-in Human, or removes it when notifications are off. */
  async syncPush() {
    if (supported()) this.permission.value = globalThis.Notification.permission
    if (!pushSupported()) return
    if (!this.enabled.value) return this.removePush()
    try {
      await this.subscribePush()
      this.pushFailed.value = false
    } catch (error) {
      this.pushFailed.value = true
      throw error
    }
  }

  /** Stops pushes to this browser, as notifications turning off or the Human signing out requires. */
  async removePush() {
    if (!pushSupported()) return
    const registration = await navigator.serviceWorker.getRegistration('/')
    const subscription = await registration?.pushManager.getSubscription()
    if (!subscription) return
    await unsubscribePodWebPush({ body: { data: { endpoint: subscription.endpoint } } }).catch(() => {})
    await subscription.unsubscribe()
  }

  private async subscribePush() {
    await navigator.serviceWorker.register(SERVICE_WORKER, { scope: '/' })
    // Push subscriptions need an active worker, which `register` does not wait for.
    const registration = await navigator.serviceWorker.ready
    const { publicKey } = await getPodWebPush()
    const key = base64URLBytes(publicKey)
    let subscription = await registration.pushManager.getSubscription()
    // A subscription made for another site key cannot receive this site's pushes.
    if (subscription && !sameBytes(subscription.options.applicationServerKey, key)) {
      await subscription.unsubscribe()
      subscription = null
    }
    subscription ??= await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key })
    const keys = subscription.toJSON().keys ?? {}
    if (!keys.p256dh || !keys.auth) return
    await subscribePodWebPush({
      body: {
        data: {
          endpoint: subscription.endpoint,
          p256dh: keys.p256dh,
          auth: keys.auth,
          userAgent: navigator.userAgent.slice(0, 1024)
        }
      }
    })
  }

  /** Shows a notification through the service worker, so a click opens the room even after the tab reloads. */
  async show(notification: PodNotification, open: (url: string) => void) {
    if (!this.enabled.peek()) return
    const options = {
      body: notification.body,
      tag: notification.tag,
      icon: '/images/pwa-192.png',
      data: { url: notification.url },
      requireInteraction: notification.decision
    }
    const registration = pushSupported() ? await navigator.serviceWorker.getRegistration('/') : undefined
    if (registration) {
      await registration.showNotification(notification.title, options)
      return
    }
    const shown = new globalThis.Notification(notification.title, options)
    shown.onclick = () => {
      globalThis.focus()
      open(notification.url)
      shown.close()
    }
  }
}

export const browserNotifications = new BrowserNotifications()

/** React Compiler tracks signal reads only on values that come from a hook, so components read the model here. */
export function useBrowserNotifications() {
  return browserNotifications
}

export function base64URLBytes(value: string): Uint8Array<ArrayBuffer> {
  const base64 = value
    .replace(/-/g, '+')
    .replace(/_/g, '/')
    .padEnd(Math.ceil(value.length / 4) * 4, '=')
  return Uint8Array.from(atob(base64), char => char.charCodeAt(0))
}

function sameBytes(current: ArrayBuffer | null | undefined, expected: Uint8Array) {
  if (!current || current.byteLength !== expected.byteLength) return false
  const bytes = new Uint8Array(current)
  return bytes.every((byte, index) => byte === expected[index])
}

/** Returns the badged title and its prefix; only a prefix that Pod added comes off again. */
export function titleWithBadge(title: string, count: number, applied = ''): [string, string] {
  const base = applied && title.startsWith(applied) ? title.slice(applied.length) : title
  const prefix = count > 0 ? `(${count > 99 ? '99+' : count}) ` : ''
  return [prefix + base, prefix]
}

let appliedBadge = ''

/** Prefixes the document title with the attention count, whichever screen set the title. */
export function applyTitleBadge(count: number) {
  const [next, prefix] = titleWithBadge(document.title, count, appliedBadge)
  appliedBadge = prefix
  if (document.title !== next) document.title = next
}
