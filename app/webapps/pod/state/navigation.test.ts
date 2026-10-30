import { expect, test } from 'bun:test'
import { computed, effect } from '@preact/signals-react'
import { routeSidebarTab } from '../sidebar'
import { isSidebarSectionActive, mergeRecentEntries, NavigationModel } from './navigation'

function storage() {
  const values = new Map<string, string>()
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => {
      values.set(key, value)
    }
  }
}

test('root preferences survive reload while branch choices stay within the document', () => {
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
  expect([...reopened.preferences.value.expanded]).toEqual([])
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
    model.refreshPreferences()
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
  expect([...model.preferences.value.expanded]).toEqual([])
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

test('a confirmed leaf closes without closing other branches', () => {
  const saved = storage()
  const model = new NavigationModel('pod', 'owner', saved)
  model.togglePage('leaf')
  model.togglePage('branch')
  model.closePage('leaf')
  model.closePage('leaf')
  expect([...model.preferences.value.expanded]).toEqual(['branch'])
  expect([...new NavigationModel('pod', 'owner', saved).preferences.value.expanded]).toEqual([])
})

test('expanding a branch only notifies that branch, while root preferences remain independent', () => {
  const model = new NavigationModel('pod', 'owner', storage())
  const left = computed(() => model.preferences.value.expanded.has('left'))
  const right = computed(() => model.preferences.value.expanded.has('right'))
  const observed: { roots: boolean[]; left: boolean[]; right: boolean[] } = { roots: [], left: [], right: [] }
  const dispose = [
    effect(() => void observed.roots.push(model.rootOpen.value.space)),
    effect(() => void observed.left.push(left.value)),
    effect(() => void observed.right.push(right.value))
  ]
  try {
    model.togglePage('left')
    expect(observed).toEqual({ roots: [true], left: [false, true], right: [false] })
    model.toggleRoot('space')
    expect(observed).toEqual({ roots: [true, false], left: [false, true], right: [false] })
    model.togglePage('right')
    model.closePage('left')
    expect(observed).toEqual({ roots: [true, false], left: [false, true, false], right: [false, true] })
  } finally {
    dispose.forEach(stop => stop())
    model[Symbol.dispose]()
  }
})

test('resuming navigation reads external root preferences and preserves its own branches', () => {
  const saved = storage()
  const reader = new NavigationModel('pod', 'owner', saved)
  const writer = new NavigationModel('pod', 'owner', saved)
  reader.togglePage('expanded-here')
  writer.toggleRoot('private')
  reader.refreshPreferences()
  expect(reader.rootOpen.value.private).toBe(false)
  expect([...reader.preferences.value.expanded]).toEqual(['expanded-here'])
})

test('reload ignores legacy branches and restores only the active page ancestors', () => {
  const saved = storage()
  saved.setItem('ankole.pod.navigation:pod:owner', JSON.stringify({ expanded: ['unrelated', 'leaf'] }))
  const model = new NavigationModel('pod', 'owner', saved)
  expect(model.preferences.value.expanded.size).toBe(0)
  model.revealPath(['root', 'parent'], 'space')
  expect([...model.preferences.value.expanded]).toEqual(['root', 'parent'])
  expect([...new NavigationModel('pod', 'owner', saved).preferences.value.expanded]).toEqual([])
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

test('only the Sidebar section that opened a page marks it', () => {
  expect(isSidebarSectionActive('recent', 'recent')).toBe(true)
  expect(isSidebarSectionActive('recent', 'private')).toBe(false)
  expect(isSidebarSectionActive('private', 'private')).toBe(true)
  expect(isSidebarSectionActive('private', 'space')).toBe(false)
  expect(isSidebarSectionActive('favorites', 'favorites')).toBe(true)
  expect(isSidebarSectionActive('favorites', 'recent')).toBe(false)
})

test('a page opened without a Sidebar section marks the tree that holds it', () => {
  expect(isSidebarSectionActive(undefined, 'space')).toBe(true)
  expect(isSidebarSectionActive(undefined, 'private')).toBe(true)
  expect(isSidebarSectionActive(undefined, 'recent')).toBe(false)
  expect(isSidebarSectionActive(undefined, 'favorites')).toBe(false)
})

test('routeSidebarTab preserves explicit keepSidebarTab when opening a recent conversation from Home', () => {
  expect(routeSidebarTab('/conversations/abc')).toBe('chat')
  expect(routeSidebarTab('/conversations/abc', { keepSidebarTab: 'home' })).toBe('home')
  expect(routeSidebarTab('/pages/abc')).toBe('home')
})
