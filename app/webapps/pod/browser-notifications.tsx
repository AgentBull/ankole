import { Button, Switch } from '@ankole/uikit'
import { AlertRegular } from '@ankole/uikit/icons'
import { useSignals } from '@preact/signals-react/runtime'
import { useQuery } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useCallback, useEffect, useId, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { podPagePath, podPagePathnameID } from '../common/pod-url'
import { conversationAttentionQuery } from './api'
import { conversationPath } from './chat/conversation-row'
import { resolvePodTarget } from './command-menu'
import { commentAttentionQuery } from './content-api'
import { SettingsSection } from './settings-layout'
import {
  applyTitleBadge,
  browserNotifications,
  chatAttentionCount,
  commentNotifications,
  roomNotifications,
  snapshotRooms,
  type PodNotification,
  ownMessageSeq,
  type RoomSnapshot,
  useBrowserNotifications
} from './state/notifications'

const viewing = (notification: PodNotification) =>
  document.visibilityState === 'visible' &&
  document.hasFocus() &&
  (notification.tag.startsWith('comments:')
    ? podPagePathnameID(location.pathname) === notification.tag.slice('comments:'.length)
    : location.pathname === notification.url)

/**
 * Turns attention changes that reach this tab into browser notifications and keeps the title badge current.
 * Web Push covers the Human while no Pod tab is open; both paths tag a notification by its room, so the browser
 * shows one notification for one room.
 */
export function PodNotifications() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const rooms = useQuery(conversationAttentionQuery)
  const comments = useQuery(commentAttentionQuery)
  const roomSnapshot = useRef<RoomSnapshot>(undefined)
  const commentSnapshot = useRef<Map<string, string>>(undefined)
  const notifications = useBrowserNotifications()
  const enabled = notifications.enabled.value

  const open = useCallback(
    (url: string) => {
      const target = resolvePodTarget(url)
      void navigate({ to: target.to, ...(target.search ? { search: target.search as never } : {}) })
    },
    [navigate]
  )
  const show = (notifications: PodNotification[]) => {
    for (const notification of notifications) {
      if (!viewing(notification)) void browserNotifications.show(notification, open).catch(() => {})
    }
  }

  // Each load moves the push subscription to the Human signed in now.
  useEffect(() => {
    if (enabled) void browserNotifications.syncPush().catch(() => {})
  }, [enabled])

  useEffect(() => {
    if (!rooms.data) return
    const previous = roomSnapshot.current
    roomSnapshot.current = snapshotRooms(rooms.data)
    if (!previous) return
    show(roomNotifications(previous, rooms.data, conversationPath, t('pod.notifications.untitled'), ownMessageSeq))
  }, [rooms.data])

  useEffect(() => {
    if (!comments.data) return
    const previous = commentSnapshot.current
    commentSnapshot.current = new Map(comments.data.map(row => [row.page.id, row.activity_at]))
    if (!previous) return
    show(
      commentNotifications(
        previous,
        comments.data,
        row => podPagePath(row.page.id, row.page.title),
        t('pod.notifications.new_comments'),
        t('pod.notifications.untitled')
      )
    )
  }, [comments.data])

  const count = chatAttentionCount(rooms.data) + (comments.data?.length ?? 0)
  useEffect(() => {
    applyTitleBadge(count)
    // Screens rename the document, so the badge follows every title change.
    const title = document.querySelector('title')
    const observer = new MutationObserver(() => applyTitleBadge(count))
    if (title) observer.observe(title, { childList: true, characterData: true, subtree: true })
    const app = navigator as Navigator & { setAppBadge?: (count?: number) => Promise<void> }
    void app.setAppBadge?.(count).catch(() => {})
    return () => observer.disconnect()
  }, [count])

  useEffect(() => {
    const opened = (event: MessageEvent) => {
      if (event.data?.type === 'ankole:open' && typeof event.data.url === 'string') open(event.data.url)
    }
    // A Human can change the permission in the browser's site settings while Pod is open.
    const refresh = () => {
      if (document.visibilityState === 'visible' && typeof Notification === 'function') {
        browserNotifications.permission.value = Notification.permission
      }
    }
    navigator.serviceWorker?.addEventListener('message', opened)
    document.addEventListener('visibilitychange', refresh)
    return () => {
      navigator.serviceWorker?.removeEventListener('message', opened)
      document.removeEventListener('visibilitychange', refresh)
    }
  }, [open])

  return null
}

// iPadOS reports a Macintosh user agent, so a touch screen tells it apart from a Mac.
const iosBrowserTab = () =>
  (/iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)) &&
  !globalThis.matchMedia?.('(display-mode: standalone)').matches

/** The personal setting that turns this device's notifications on or off. */
export function NotificationSettings() {
  useSignals()
  const { t } = useTranslation()
  const id = useId()
  const notifications = useBrowserNotifications()
  const permission = notifications.permission.value
  const enabled = notifications.enabled.value
  return (
    <SettingsSection title={t('pod.notifications.title')} description={t('pod.notifications.description')}>
      <div className="grid gap-4">
        <div className="flex items-center justify-between gap-4">
          <label htmlFor={id} className="text-sm font-medium">
            {t('pod.notifications.enable')}
          </label>
          <Switch
            id={id}
            checked={enabled}
            disabled={permission === 'unsupported' || permission === 'denied'}
            onCheckedChange={checked =>
              void (checked === true ? browserNotifications.enable() : browserNotifications.disable())
            }
          />
        </div>
        {enabled && notifications.pushFailed.value && (
          <p className="text-sm text-fg-secondary">{t('pod.notifications.push_failed')}</p>
        )}
        {permission === 'denied' && <p className="text-sm text-fg-secondary">{t('pod.notifications.blocked')}</p>}
        {permission === 'unsupported' && (
          <p className="text-sm text-fg-secondary">
            {t(iosBrowserTab() ? 'pod.notifications.ios_home_screen' : 'pod.notifications.unsupported')}
          </p>
        )}
        {enabled && (
          <div>
            <Button
              variant="outline"
              size="sm"
              onClick={() =>
                void browserNotifications.show(
                  {
                    tag: 'ankole:test',
                    title: t('pod.notifications.test_title'),
                    body: t('pod.notifications.test_body'),
                    url: location.pathname,
                    decision: false
                  },
                  () => {}
                )
              }>
              {t('pod.notifications.test')}
            </Button>
          </div>
        )}
      </div>
    </SettingsSection>
  )
}

/** A quiet offer in the composer dock, shown while the browser has not been asked yet. */
export function NotificationPrompt() {
  useSignals()
  const { t } = useTranslation()
  const notifications = useBrowserNotifications()
  if (!notifications.shouldPrompt.value) return null
  return (
    <div className="pod-chat-invite-notice">
      <AlertRegular aria-hidden className="size-4 shrink-0" />
      <span>{t('pod.notifications.prompt')}</span>
      <Button size="xs" variant="ghost" onClick={() => void browserNotifications.enable()}>
        {t('pod.notifications.prompt_enable')}
      </Button>
      <Button size="xs" variant="ghost" onClick={() => browserNotifications.dismissPrompt()}>
        {t('pod.notifications.prompt_dismiss')}
      </Button>
    </div>
  )
}
