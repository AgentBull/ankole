import { describe, expect, test } from 'bun:test'
import { DocumentPresenceModel } from './document-presence'

describe('document presence', () => {
  test('one person has one avatar while each of their other sessions keeps its own selection', () => {
    const model = new DocumentPresenceModel()
    model.self.value = 'this-tab'
    model.setConnection('connected')
    model.sync([
      {
        id: 'human',
        metas: [
          { session_id: 'this-tab', name: 'Human', mode: 'viewing', selection: null },
          {
            session_id: 'other-tab',
            name: 'Human',
            mode: 'editing',
            selection: { revision: 5, anchor: 2, head: 4 }
          }
        ]
      },
      { id: 'agent', metas: [{ session_id: 'agent-session', name: 'Agent', mode: 'viewing' }] }
    ])
    expect(model.members.value).toHaveLength(2)
    expect(model.members.value.find(member => member.uid === 'human')?.mode).toBe('editing')
    expect(model.peers.value.map(peer => peer.id)).toEqual(['other-tab', 'agent-session'])
    expect(model.peers.value[0]?.selection).toEqual({ revision: 5, anchor: 2, head: 4 })
    model[Symbol.dispose]()
  })

  test('disconnect hides stale sessions until a fresh presence state arrives', () => {
    const model = new DocumentPresenceModel()
    model.setConnection('connected')
    model.sync([{ id: 'human', metas: [{ session_id: 'old-session', name: 'Human' }] }])
    model.setConnection('disconnected')
    expect(model.members.value).toEqual([])
    expect(model.peers.value).toEqual([])
    model.setConnection('connected')
    expect(model.members.value).toEqual([])
    model.self.value = 'new-session'
    model.sync([{ id: 'human', metas: [{ session_id: 'new-session', name: 'Human' }] }])
    expect(model.members.value).toHaveLength(1)
    expect(model.peers.value).toEqual([])
    model[Symbol.dispose]()
  })
})
