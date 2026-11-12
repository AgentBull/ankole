import { expect, test } from 'bun:test'
import {
  CHAT_INSPECTOR_DEFAULT_WIDTH,
  CHAT_INSPECTOR_MIN_WIDTH,
  ChatInspectorLayoutModel
} from './chat-inspector-layout'

const WIDTH_STORAGE_KEY = 'ankole.pod.chat-inspector-width'

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

test('the background-work inspector opens narrow until the viewer has chosen a width', () => {
  expect(CHAT_INSPECTOR_DEFAULT_WIDTH).toBe(440)
  for (const [raw, expected] of [
    [null, CHAT_INSPECTOR_DEFAULT_WIDTH],
    ['invalid', CHAT_INSPECTOR_DEFAULT_WIDTH],
    ['100', CHAT_INSPECTOR_MIN_WIDTH],
    ['720.6', 721]
  ] as const) {
    expect(new ChatInspectorLayoutModel(storage(raw)).width.value).toBe(expected)
  }
})

test('a dragged inspector width is saved when the drag ends and reopens at that width', () => {
  const saved = storage()
  const model = new ChatInspectorLayoutModel(saved)
  model.previewWidth(680)
  expect(model.width.value).toBe(680)
  expect(saved.getItem(WIDTH_STORAGE_KEY)).toBeNull()

  model.commitWidth(model.width.peek())
  expect(new ChatInspectorLayoutModel(saved).width.value).toBe(680)
})
