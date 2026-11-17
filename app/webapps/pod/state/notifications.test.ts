import { describe, expect, test } from 'bun:test'
import {
  base64URLBytes,
  chatAttentionCount,
  commentNotifications,
  roomNotifications,
  snapshotRooms,
  titleWithBadge
} from './notifications'

type Room = Parameters<typeof snapshotRooms>[0][number]
type CommentRow = Parameters<typeof commentNotifications>[1][number]

const room = (overrides: Partial<Room>): Room =>
  ({
    id: 'room-1',
    title: 'Quarterly report',
    conversationKind: 'group',
    agents: [{ uid: 'researcher', displayName: 'Researcher' }],
    rowStatus: 'idle',
    viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 0 },
    lastNotifiableSeq: 1,
    latestMessagePreview: 'Draft is ready',
    ...overrides
  }) as Room

const path = (row: Pick<Room, 'id'>) => `/conversations/${row.id}`
const notify = (before: Room[], after: Room[]) => roomNotifications(snapshotRooms(before), after, path, 'Conversation')

describe('roomNotifications', () => {
  test('notifies when a new message leaves a room unread', () => {
    const [notification] = notify(
      [room({ rowStatus: 'streaming', lastNotifiableSeq: 3 })],
      [room({ rowStatus: 'unread', lastNotifiableSeq: 4 })]
    )
    expect(notification).toEqual({
      tag: 'room-1',
      title: 'Quarterly report',
      body: 'Draft is ready',
      url: '/conversations/room-1',
      decision: false
    })
  })

  test('notifies a room that was not in the attention list before', () => {
    expect(notify([], [room({ rowStatus: 'unread', lastNotifiableSeq: 2 })])).toHaveLength(1)
  })

  test('stays quiet when an unread room only gains process cards', () => {
    const unread = room({ rowStatus: 'unread', lastNotifiableSeq: 4 })
    expect(notify([unread], [unread])).toEqual([])
  })

  test('notifies again for each new notifiable message in an unread room', () => {
    expect(
      notify(
        [room({ rowStatus: 'unread', lastNotifiableSeq: 4 })],
        [room({ rowStatus: 'unread', lastNotifiableSeq: 5 })]
      )
    ).toHaveLength(1)
  })

  test('notifies once when a room starts waiting on a decision', () => {
    const waiting = room({ rowStatus: 'waiting_choice', lastNotifiableSeq: 5 })
    expect(notify([room({ rowStatus: 'streaming', lastNotifiableSeq: 4 })], [waiting])[0]?.decision).toBe(true)
    expect(notify([waiting], [waiting])).toEqual([])
  })

  test('names a colleague DM by its colleague', () => {
    const [notification] = notify([], [room({ conversationKind: 'colleague_dm', rowStatus: 'unread' })])
    expect(notification?.title).toBe('Researcher')
  })

  test('notifies a new message while the room also shows other work', () => {
    expect(
      notify(
        [room({ rowStatus: 'running_background', lastNotifiableSeq: 3 })],
        [room({ rowStatus: 'running_background', lastNotifiableSeq: 4 })]
      )
    ).toHaveLength(1)
  })

  test('stays quiet for read, muted, or own messages', () => {
    const read = room({ rowStatus: 'idle', lastNotifiableSeq: 4 })
    read.viewer = { ...read.viewer, lastReadSeq: 4 }
    const muted = room({ rowStatus: 'idle', lastNotifiableSeq: 4 })
    muted.viewer = { ...muted.viewer, muted: true }
    expect(notify([], [read])).toEqual([])
    expect(notify([], [muted])).toEqual([])
    expect(
      roomNotifications(new Map(), [room({ rowStatus: 'unread', lastNotifiableSeq: 4 })], path, 'Conversation', () => 4)
    ).toEqual([])
  })

  test('a muted room still notifies a decision', () => {
    const waiting = room({ rowStatus: 'waiting_choice', lastNotifiableSeq: 4 })
    waiting.viewer = { ...waiting.viewer, muted: true }
    expect(notify([], [waiting])[0]?.decision).toBe(true)
  })
})

describe('commentNotifications', () => {
  const row = (activity: string) =>
    ({ page: { id: 'page-1', title: 'Plan' }, activity_at: activity, unread_count: 1 }) as unknown as CommentRow

  test('notifies when comment activity moves forward', () => {
    const previous = new Map([['page-1', '2026-11-17T01:00:00Z']])
    expect(commentNotifications(previous, [row('2026-11-17T02:00:00Z')], () => '/pages/p', 'New', 'Page')).toEqual([
      { tag: 'comments:page-1', title: 'Plan', body: 'New', url: '/pages/p', decision: false }
    ])
    expect(commentNotifications(previous, [row('2026-11-17T01:00:00Z')], () => '/pages/p', 'New', 'Page')).toEqual([])
  })
})

test('counts the same attention as the Chat tab badge', () => {
  expect(
    chatAttentionCount([
      room({ rowStatus: 'unread' }),
      room({ rowStatus: 'unread', conversationKind: 'assistant_task' }),
      room({ rowStatus: 'waiting_choice', conversationKind: 'assistant_task' }),
      room({ rowStatus: 'streaming' })
    ])
  ).toBe(2)
})

test('the title badge replaces only the prefix it added', () => {
  const [badged, prefix] = titleWithBadge('Chat · Ankole', 3)
  expect(badged).toBe('(3) Chat · Ankole')
  expect(titleWithBadge(badged, 120, prefix)).toEqual(['(99+) Chat · Ankole', '(99+) '])
  expect(titleWithBadge(badged, 0, prefix)).toEqual(['Chat · Ankole', ''])
  // A Page that is itself titled "(2) …" keeps its title.
  expect(titleWithBadge('(2) Plan', 0)).toEqual(['(2) Plan', ''])
})

test('decodes the unpadded base64url VAPID key', () => {
  expect([...base64URLBytes('BP8')]).toEqual([4, 255])
})
