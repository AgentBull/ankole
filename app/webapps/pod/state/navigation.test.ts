import { expect, test } from 'bun:test'
import { NavigationModel } from './navigation'

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
  expect(first.preferences.value.collapsed.has('parent')).toBe(true)
  first.toggleRoot('space')
  const reopened = new NavigationModel('pod', 'owner', saved)
  expect(reopened.preferences.value.rootOpen).toEqual({ space: false, private: true })
  expect([...reopened.preferences.value.collapsed]).toEqual(['parent'])
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
    expect(separate.preferences.value.collapsed.size).toBe(0)
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
    expect(model.preferences.value.collapsed.has('parent')).toBe(true)
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
    JSON.stringify({ rootOpen: { space: false }, collapsed: ['parent', null, 7], pages: [{ title: 'obsolete' }] })
  )
  expect(model.preferences.value.rootOpen).toEqual({ space: false, private: true })
  expect([...model.preferences.value.collapsed]).toEqual(['parent'])
  expect(Object.keys(model.preferences.value).sort()).toEqual(['collapsed', 'rootOpen'])
  expect(writes).toBe(0)
})
