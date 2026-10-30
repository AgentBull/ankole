import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { TopicConnection } from '../realtime'

export type DocumentPeer = {
  id: string
  uid: string
  name: string
  avatar_url?: string
  mode: 'editing' | 'viewing'
  selection: { revision: number; anchor: number; head: number } | null
}
const colors = ['#9a3d5d', '#2469a2', '#28704b', '#8059a5', '#a16020', '#287580']
export function peerColor(uid: string): string {
  let hash = 0
  for (const character of uid) hash = (hash * 31 + character.charCodeAt(0)) >>> 0
  return colors[hash % colors.length]!
}

/** Presence is a live projection of document sessions, separate from sharing permissions. */
export const DocumentPresenceModel = createModel(() => {
  const connection = signal<TopicConnection>('connecting')
  const self = signal('')
  const sessions = signal<readonly DocumentPeer[]>([])
  const peers = computed(() => sessions.value.filter(peer => peer.id !== self.value))
  const members = computed(() => {
    const people = new Map<string, DocumentPeer>()
    for (const session of sessions.value) {
      if (!people.has(session.uid) || session.mode === 'editing') people.set(session.uid, session)
    }
    return [...people.values()].sort((a, b) => a.uid.localeCompare(b.uid))
  })
  return {
    connection,
    self,
    sessions,
    peers,
    members,
    setConnection(status: TopicConnection) {
      batch(() => {
        connection.value = status
        if (status !== 'connected') sessions.value = []
      })
    },
    sync(entries: { id: string; metas: Record<string, unknown>[] }[]) {
      sessions.value = entries.flatMap(entry =>
        entry.metas.flatMap(meta => {
          if (typeof meta.session_id !== 'string') return []
          const selection = meta.selection as DocumentPeer['selection']
          return [
            {
              id: meta.session_id,
              uid: entry.id,
              name: typeof meta.name === 'string' ? meta.name : entry.id,
              avatar_url: typeof meta.avatar_url === 'string' ? meta.avatar_url : undefined,
              mode: meta.mode === 'editing' ? ('editing' as const) : ('viewing' as const),
              selection:
                selection &&
                Number.isInteger(selection.revision) &&
                Number.isInteger(selection.anchor) &&
                Number.isInteger(selection.head)
                  ? selection
                  : null
            }
          ]
        })
      )
    }
  }
})
