import { beforeAll, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../../common/i18n'
import { repositoryRoot } from '../../../scripts/edition'
import MarkdownRenderer from '../markdown-renderer'
import { uiBlockCatalog } from './catalog'
import { compileUIBlock } from './compile'
import UIBlock from './ui-block'

beforeAll(() => loadLocale('en-US'))

const markup = (code: string, streaming = false) => renderToStaticMarkup(<UIBlock code={code} streaming={streaming} />)

const ROOT = '{"op":"add","path":"/root","value":"main"}'
const element = (key: string, type: string, props: object, children: string[] = [], rest: object = {}) =>
  JSON.stringify({ op: 'add', path: `/elements/${key}`, value: { type, props, children, ...rest } })
const block = (...lines: string[]) => [ROOT, ...lines].join('\n')

const reference = `${uiBlockCatalog.prompt()}\n`
/** The example that the Skill reference shows to the model. */
const example = /```ui\n([\s\S]*?)\n```/.exec(reference)![1]!

/** A block that Pod cannot use shows its source and renders none of its elements. */
function expectSource(code: string) {
  expect(compileUIBlock(code)).toBeUndefined()
  const html = markup(code)
  expect(html).toContain('pod-chat-code-body')
  expect(html).not.toContain('chat-ui-block')
}

test('the Skill reference in the library is the one the catalog generates', () => {
  const file = path.join(repositoryRoot, 'app/library/skills/visualization/references/chat-ui-block.md')
  // Run `bun scripts/ui-block-reference.ts` in app/webapps after changing the catalog.
  expect(readFileSync(file, 'utf8')).toBe(reference)
})

test('the reference example uses catalog components and renders its initial view', () => {
  const spec = compileUIBlock(example)!
  for (const item of Object.values(spec.elements)) expect(uiBlockCatalog.componentNames).toContain(item.type)
  const html = markup(example)
  expect(html).toContain('East revenue')
  expect(html).toContain('Break down by team')
  // The west figure waits behind its `visible` condition until the reader switches the toggle.
  expect(html).not.toContain('West revenue')
})

test('a streamed block shows what has arrived and never its source', () => {
  for (let length = 0; length <= example.length; length++) {
    const prefix = example.slice(0, length)
    const html = markup(prefix, true)
    expect(html).not.toContain('pod-chat-code-body')
    if (!compileUIBlock(prefix, true)) expect(html).toBe('')
  }
  const untilToggle = example.split('\n').slice(0, 4).join('\n')
  expect(markup(untilToggle, true)).toContain('East')
  expect(markup(untilToggle, true)).not.toContain('East revenue')
  // The same lines are not a complete block: once settled, the children that never arrived make it unusable.
  expectSource(untilToggle)
})

test('a settled block without a usable spec shows its source', () => {
  expectSource('not a patch')
  expectSource('{"op":"add","path":"/root","value":"missing"}')
  expectSource('{"op":"test","path":"/root","value":"x"}')
  expectSource(block(element('main', 'Marquee', { text: 'An unknown component' })))
  expectSource(block(element('main', 'Stack', {}, ['rows']), element('rows', 'Table', { rows: [] })))
  expectSource(block(element('main', 'Text', { text: { $state: '/missing' } })))
})

test('a block cannot contain itself or expand past the element budget', () => {
  expectSource(block(element('main', 'Stack', {}, ['card']), element('card', 'Stack', {}, ['main'])))
  expectSource(block(element('main', 'Stack', {}, ['main'])))

  // Each Stack names the next one twice, so 31 lines would expand to two to the power of 30 elements.
  const layers = Array.from({ length: 30 }, (_, index) =>
    element(index ? `layer-${index}` : 'main', 'Stack', {}, [`layer-${index + 1}`, `layer-${index + 1}`])
  )
  const started = performance.now()
  expectSource(block(...layers, element('layer-30', 'Text', { text: 'leaf' })))
  expect(performance.now() - started).toBeLessThan(1000)

  const wide = (count: number) =>
    block(
      element(
        'main',
        'Stack',
        {},
        Array.from({ length: count }, (_, index) => `text-${index}`)
      ),
      ...Array.from({ length: count }, (_, index) => element(`text-${index}`, 'Text', { text: `Line ${index}` }))
    )
  expect(Object.keys(compileUIBlock(wide(100))!.elements)).toHaveLength(101)
  expectSource(wide(600))
})

test('a block uses the catalog actions only and cannot open a confirmation dialog', () => {
  const press = (binding: object) =>
    block(element('main', 'Button', { label: 'Continue' }, [], { on: { press: binding } }))
  const kept = compileUIBlock(
    press({
      action: 'reply',
      params: { text: 'Continue' },
      confirm: { title: 'Session expired', message: 'Sign in again', confirmLabel: 'Sign in' },
      onSuccess: { navigate: 'https://example.com' }
    })
  )!
  expect(kept.elements.main!.on).toEqual({ press: [{ action: 'reply', params: { text: 'Continue' } }] })
  expect(markup(press({ action: 'setState', params: { statePath: '/open', value: true } }))).toContain('Continue')

  // The actions of Ankole's own cards and the rest of json-render's built-in actions are not block actions.
  for (const action of ['answer_choice', 'submit_form', 'resolve', 'pushState', 'removeState', 'validateForm']) {
    expectSource(press({ action, params: {} }))
  }
})

test('a block cannot use the elements of the Clarify card and the Action Card, nor repeat, watch or slots', () => {
  expectSource(
    block(
      element('main', 'InteractionCard', { kind: 'approval', title: 'Approval required', state: 'pending' }, ['go']),
      element('go', 'ActionButton', { label: 'Confirm', variant: 'default', size: 'sm', disabled: false })
    )
  )
  for (const type of ['Choice', 'QuickAnswer', 'FormField', 'Outcome', 'PageLink', 'Disclosure']) {
    expectSource(block(element('main', 'Stack', {}, ['inner']), element('inner', type, { label: 'x', text: 'x' })))
  }
  const item = element('item', 'Text', { text: 'x' })
  expectSource(block(element('main', 'Stack', {}, ['item'], { repeat: { statePath: '/items' } }), item))
  expectSource(
    block(element('main', 'Stack', {}, ['item'], { watch: { '/x': { action: 'setState', params: {} } } }), item)
  )
  expectSource(block(element('main', 'Stack', {}, [], { slots: { header: ['item'] } }), item))
})

test('every catalog component renders from a spec', () => {
  const rows = [
    { team: 'Alpha', open: 12, done: 30 },
    { team: 'Beta', open: 4, done: null }
  ]
  const children = ['tabs', 'details', 'note', 'progress', 'badge', 'chart']
  const code = block(
    element('main', 'Stack', { gap: 'lg' }, children),
    element(
      'tabs',
      'Tabs',
      {
        tabs: [
          { value: 'numbers', label: 'Numbers' },
          { value: 'table', label: 'By team' }
        ]
      },
      ['numbers', 'table']
    ),
    element('numbers', 'TabPanel', { value: 'numbers' }, ['grid']),
    element('grid', 'Grid', { columns: 2 }, ['stat', 'card']),
    element('stat', 'Stat', { label: 'Open issues', value: 16, delta: '-3', sparkline: [20, 18, 16] }),
    element('card', 'Card', { title: 'Scope', description: 'This sprint' }, ['text']),
    element('text', 'Text', { text: 'Two teams', tone: 'secondary' }),
    element('table', 'TabPanel', { value: 'table' }, ['rows']),
    element('rows', 'Table', {
      columns: [
        { key: 'team', label: 'Team' },
        { key: 'open', label: 'Open', align: 'end' }
      ],
      rows,
      sortable: true
    }),
    element('details', 'Accordion', {}, ['method']),
    element('method', 'AccordionItem', { title: 'How this was counted' }, []),
    element('note', 'Alert', { title: 'Heads up', text: 'Beta has no finished work yet', variant: 'warning' }),
    element('progress', 'Progress', { label: 'Sprint', value: 40 }),
    element('badge', 'Badge', { text: 'On track', variant: 'success' }),
    element('chart', 'Chart', { type: 'column', data: rows, xField: 'team', yField: 'open', title: 'Open by team' })
  )
  const used = new Set(Object.values(compileUIBlock(code)!.elements).map(item => item.type))
  // The reference example covers the two components that this spec leaves out.
  expect([...used, 'Button', 'ToggleGroup'].sort()).toEqual([...uiBlockCatalog.componentNames].sort())
  const html = markup(code)
  for (const text of [
    'Numbers',
    'By team',
    'Open issues',
    'Scope',
    'Two teams',
    'How this was counted',
    'Heads up',
    'Sprint',
    'On track'
  ]) {
    expect(html).toContain(text)
  }
})

test('only an Agent reply renders the block, and it hands the block its source unchanged', () => {
  const text = `Summary first.\n\n\`\`\`ui\n${example}\n\`\`\`\n\nDone.`
  const render = (generated: boolean, streaming: boolean) =>
    renderToStaticMarkup(<MarkdownRenderer text={text} generated={generated} streaming={streaming} />)
      .replace(/<[^>]+>/g, '')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&amp;', '&')
  // A static render stops at the lazy boundary, whose settled fallback shows the source the block receives.
  expect(render(true, false)).toContain(example)
  expect(render(true, false)).toContain('Summary first.')
  // While an Agent reply streams, the block shows nothing until it loads; a Human's fenced block is always code.
  expect(render(true, true)).not.toContain('"op"')
  expect(render(false, true)).toContain(example)
})
