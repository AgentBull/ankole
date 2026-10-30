import { beforeAll, expect, test } from 'bun:test'
import { Attributes, type Elt } from '../src/core/doc'
import {
  codeHighlight,
  codeHighlightField,
  loadCodeHighlighter,
  codeLanguageLabel,
  codeLanguageState,
  filterCodeLanguages
} from '../src/editor/code-block'
import { GardSelection } from '../src/core/state'
import { headlessState } from '../src/editor/extension'

beforeAll(() => loadCodeHighlighter())

function classes(source: string): string[] {
  const ranges = codeHighlight(headlessState(source))
  const found: string[] = []
  for (const cursor = ranges.cursor(); cursor.value; cursor.next()) {
    const elt = (cursor.value as unknown as { elt: Elt }).elt
    const name = Attributes.get(elt.attrs, 'class')
    if (name) found.push(name)
  }
  return found
}

test('a code block paints Kirari token classes over its text', () => {
  expect(classes('```js\nconst answer = 42\n```')).toEqual(
    expect.arrayContaining(['kirari-keyword', 'kirari-variable', 'kirari-operator', 'kirari-number'])
  )
})

test('plain text and unknown languages stay unhighlighted', () => {
  expect(classes('```\nconst answer = 42\n```')).toEqual([])
  expect(classes('```unknown-language\nconst answer = 42\n```')).toEqual([])
})

test('highlight decorations survive non-document updates and refresh on edits', () => {
  const state = headlessState('```js\nconst answer = 42\n```')
  const first = state.field(codeHighlightField)
  const moved = state.update({ selection: GardSelection.cursor(1) }).state
  expect(moved.field(codeHighlightField)).toBe(first)
  const edited = moved.update({ changes: { from: 14, to: 15 } }).state
  expect(edited.field(codeHighlightField)).not.toBe(first)
})

test('language aliases resolve to their grammar and label', () => {
  expect(codeLanguageLabel(undefined)).toBe('Plain Text')
  expect(codeLanguageLabel('  ')).toBe('Plain Text')
  expect(codeLanguageLabel('js')).toBe('JavaScript')
  expect(codeLanguageLabel('py')).toBe('Python')
  expect(codeLanguageLabel('no-such-language')).toBe('no-such-language')
})

test('missing, explicit, and unknown language values stay distinct and agree on Plain Text', () => {
  expect(codeLanguageState(undefined)).toEqual({ raw: undefined, canonical: 'plaintext' })
  expect(codeLanguageState('  ')).toEqual({ raw: undefined, canonical: 'plaintext' })
  expect(codeLanguageState('plaintext')).toEqual({ raw: 'plaintext', canonical: 'plaintext' })
  expect(codeLanguageState('js')).toEqual({ raw: 'js', canonical: 'javascript' })
  expect(codeLanguageState('unknown-language')).toEqual({
    raw: 'unknown-language',
    canonical: null
  })
})

test('the language picker searches labels, names, and aliases', () => {
  expect(filterCodeLanguages('py').map(option => option.id)).toEqual(['python'])
  expect(filterCodeLanguages('c#').map(option => option.id)).toEqual(['csharp'])
  expect(filterCodeLanguages('golang').map(option => option.id)).toEqual(['go'])
  expect(filterCodeLanguages('').map(option => option.id)[0]).toBe('plaintext')
})
