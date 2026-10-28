import { expect, test } from 'bun:test'
import { routeSidebarTab } from '../sidebar'
import { mergeRecentEntries, NavigationModel } from './navigation'

function storage() {
  const values = new Map<string, string>()
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => {
      values.set(key, value)
    }
  }
}

test('navigation restores before its first read and closing a root retains branch choices', () => {
  const saved = storage()
  const first = new NavigationModel('pod', 'owner', saved)
  first.togglePage('parent')
  first.toggleRoot('space')
  first.toggleRoot('space')
  expect(first.preferences.value.expanded.has('parent')).toBe(true)
  first.toggleRoot('space')
  first.toggleRoot('recent')
  const reopened = new NavigationModel('pod', 'owner', saved)
  expect(reopened.preferences.value.rootOpen).toEqual({
    recent: false,
    favorites: true,
    space: false,
    private: true
  })
  expect([...reopened.preferences.value.expanded]).toEqual(['parent'])
})

test('navigation preferences belong to both the Pod and the pinned document identity', () => {
  const saved = storage()
  const owner = new NavigationModel('pod', 'owner', saved)
  owner.toggleRoot('space')
  owner.togglePage('parent')
  for (const [pod, identity] of [
    ['other-pod', 'owner'],
    ['pod', 'member']
  ]) {
    const separate = new NavigationModel(pod, identity, saved)
    expect(separate.preferences.value.rootOpen.space).toBe(true)
    expect(separate.preferences.value.expanded.size).toBe(0)
  }
  expect(new NavigationModel('pod', 'owner', saved).preferences.value.rootOpen.space).toBe(false)
})

test('unavailable or malformed storage cannot prevent local navigation choices', () => {
  for (const saved of [
    {
      getItem: () => '{broken',
      setItem: () => {
        throw new Error('Quota exceeded')
      }
    },
    {
      getItem: () => {
        throw new Error('Storage blocked')
      },
      setItem: () => {
        throw new Error('Storage blocked')
      }
    }
  ]) {
    const model = new NavigationModel('pod', 'owner', saved)
    model.toggleRoot('space')
    model.togglePage('parent')
    expect(model.preferences.value.rootOpen.space).toBe(false)
    expect(model.preferences.value.expanded.has('parent')).toBe(true)
  }
})

test('an external preference update does not write it back or restore page data', () => {
  let writes = 0
  const model = new NavigationModel('pod', 'owner', {
    getItem: () => null,
    setItem: () => {
      writes++
    }
  })
  model.restore(
    JSON.stringify({
      rootOpen: { space: false, favorites: false },
      expanded: ['parent', null, 7],
      pages: [{ title: 'obsolete' }]
    })
  )
  expect(model.preferences.value.rootOpen).toEqual({
    recent: true,
    favorites: false,
    space: false,
    private: true
  })
  expect([...model.preferences.value.expanded]).toEqual(['parent'])
  expect(Object.keys(model.preferences.value).sort()).toEqual(['expanded', 'rootOpen'])
  expect(writes).toBe(0)
})

test('new navigation preferences leave branches closed until the user expands them', () => {
  const model = new NavigationModel('pod', 'owner', storage())
  expect(model.preferences.value.expanded.size).toBe(0)
  model.togglePage('root')
  expect(model.preferences.value.expanded.has('root')).toBe(true)
  model.togglePage('root')
  expect(model.preferences.value.expanded.has('root')).toBe(false)
  model[Symbol.dispose]()
})

test('mergeRecentEntries interleaves visited pages and active conversations by interaction timestamp', () => {
  const merged = mergeRecentEntries(
    [
      { id: 'page-older-edit-recent-visit', updated_at: '2026-10-20T00:00:00Z', visited_at: '2026-10-28T03:00:00Z' },
      { id: 'page-earlier-visit', updated_at: '2026-10-28T02:00:00Z', visited_at: '2026-10-28T01:00:00Z' }
    ],
    [
      { id: 'chat-latest', lastActivityAt: '2026-10-28T03:30:00Z' },
      { id: 'chat-middle', lastActivityAt: '2026-10-28T02:00:00Z' }
    ]
  )
  expect(merged.map(entry => `${entry.kind}:${entry.id}`)).toEqual([
    'conversation:chat-latest',
    'page:page-older-edit-recent-visit',
    'conversation:chat-middle',
    'page:page-earlier-visit'
  ])
})

test('routeSidebarTab preserves explicit keepSidebarTab when opening a recent conversation from Home', () => {
  expect(routeSidebarTab('/conversations/abc')).toBe('chat')
  expect(routeSidebarTab('/conversations/abc', { keepSidebarTab: 'home' })).toBe('home')
  expect(routeSidebarTab('/pages/abc')).toBe('home')
})
