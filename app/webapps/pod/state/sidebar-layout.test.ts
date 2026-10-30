import { expect, test } from 'bun:test'
import { POD_SIDEBAR_MAX_WIDTH, POD_SIDEBAR_MIN_WIDTH, SidebarLayoutModel } from './sidebar-layout'

const WIDTH_STORAGE_KEY = 'ankole.pod.sidebar-width'

function storage(initial?: string | null) {
  const values = new Map<string, string>()
  if (initial != null) values.set(WIDTH_STORAGE_KEY, initial)
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => {
      values.set(key, value)
    }
  }
}

test('sidebar width defaults to its minimum and normalizes persisted values', () => {
  expect(POD_SIDEBAR_MIN_WIDTH).toBe(248)
  for (const [raw, expected] of [
    [null, POD_SIDEBAR_MIN_WIDTH],
    ['invalid', POD_SIDEBAR_MIN_WIDTH],
    ['100', POD_SIDEBAR_MIN_WIDTH],
    ['320.4', 320],
    ['1000', POD_SIDEBAR_MAX_WIDTH]
  ] as const) {
    expect(new SidebarLayoutModel(storage(raw)).width.value).toBe(expected)
  }
})

test('drag previews stay in memory and committing restores the width in a new model', () => {
  const saved = storage('320')
  const model = new SidebarLayoutModel(saved)
  expect(model.width.value).toBe(320)

  model.previewWidth(376)
  expect(model.width.value).toBe(376)
  expect(saved.getItem(WIDTH_STORAGE_KEY)).toBe('320')

  model.commitWidth(model.width.peek())
  expect(saved.getItem(WIDTH_STORAGE_KEY)).toBe('376')
  expect(new SidebarLayoutModel(saved).width.value).toBe(376)

  model.commitWidth(POD_SIDEBAR_MIN_WIDTH - 100)
  expect(model.width.value).toBe(POD_SIDEBAR_MIN_WIDTH)
  expect(saved.getItem(WIDTH_STORAGE_KEY)).toBe(String(POD_SIDEBAR_MIN_WIDTH))
})

test('storage failures do not prevent local sidebar resizing', () => {
  const model = new SidebarLayoutModel({
    getItem: () => {
      throw new Error('Storage blocked')
    },
    setItem: () => {
      throw new Error('Storage blocked')
    }
  })
  expect(model.width.value).toBe(POD_SIDEBAR_MIN_WIDTH)
  model.commitWidth(360)
  expect(model.width.value).toBe(360)
})
