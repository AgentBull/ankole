import { resolveActionParam } from '@json-render/core'
import { beforeAll, expect, spyOn, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../../common/i18n'
import { repositoryRoot } from '../../../scripts/edition'
import MarkdownRenderer from '../markdown-renderer'
import { uiBlockCatalog } from './catalog'
import { compileUIBlock, explainUIBlockFailure, validateUIBlockState } from './compile'
import { recordUIBlockOutcome, uiBlockOutcomeListeners, type UIBlockOutcome } from './outcome'
import UIBlock from './ui-block'
import { rememberViewState } from './view-state'

beforeAll(() => loadLocale('en-US'))

const markup = (code: string, streaming = false) => renderToStaticMarkup(<UIBlock code={code} streaming={streaming} />)

const ROOT = '{"op":"add","path":"/root","value":"main"}'
const statePatch = (name: string, value: unknown) => JSON.stringify({ op: 'add', path: `/state/${name}`, value })
const element = (key: string, type: string, props: object, children: string[] = [], rest: object = {}) =>
  JSON.stringify({ op: 'add', path: `/elements/${key}`, value: { type, props, children, ...rest } })
const block = (...lines: string[]) => [ROOT, ...lines].join('\n')

const reference = `${uiBlockCatalog.prompt()}\n`
/** The examples that the Skill reference shows to the model, the first of which the tests below take apart. */
const examples = [...reference.matchAll(/```ui\n([\s\S]*?)\n```/g)].map(match => match[1]!)
const example = examples[0]!

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

test('the reference example uses catalog components, renders its initial view and interpolates dynamic reply text', () => {
  const spec = compileUIBlock(example)!
  for (const item of Object.values(spec.elements)) expect(uiBlockCatalog.componentNames).toContain(item.type)
  const html = markup(example)
  expect(html).toContain('East revenue')
  expect(html).toContain('Break down by team')
  // The west figure waits behind its `visible` condition until the reader switches the toggle.
  expect(html).not.toContain('West revenue')

  // Switching `/region` updates the follow-up reply prompt through `$template` without duplicating the button.
  const press = spec.elements.more!.on!.press!
  const binding = Array.isArray(press) ? press[0]! : press
  const textParam = binding.params!.text
  expect(resolveActionParam(textParam, { stateModel: { region: 'east' } })).toBe('Break the east region down by team')
  expect(resolveActionParam(textParam, { stateModel: { region: 'west' } })).toBe('Break the west region down by team')
})

test('a streamed block shows ready branches, holds back pending children, and tolerates root arriving last', () => {
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

  // A child waiting on a later `/state` line stays pending while streaming so ready siblings stay on screen.
  const waitingOnState = block(
    element('main', 'Stack', {}, ['ready', 'later']),
    element('ready', 'Text', { text: 'Already here' }),
    element('later', 'Tabs', { tabs: { $state: '/tabs' } }, [])
  )
  const midStream = markup(waitingOnState, true)
  expect(midStream).toContain('Already here')
  expectSource(waitingOnState)
  const completed = [waitingOnState, statePatch('tabs', [{ value: 'one', label: 'Tab One' }])].join('\n')
  expect(markup(completed, false)).toContain('Tab One')

  // Elements and state emitted before `/root` compile cleanly once `/root` arrives.
  const rootLast = [
    statePatch('title', 'Bottom-up build'),
    element('leaf', 'Text', { text: { $state: '/title' } }),
    element('main', 'Stack', {}, ['leaf']),
    ROOT
  ].join('\n')
  expect(markup(rootLast)).toContain('Bottom-up build')
})

test('a settled block without a usable spec shows its source', () => {
  expect(compileUIBlock('', false)).toBeUndefined()
  // Truncated trailing JSON in a settled block disqualifies the block instead of silently dropping lines.
  expectSource([block(element('main', 'Text', { text: 'Hi' })), '{"op":"add","path":"/state/cut'].join('\n'))

  for (const invalid of [
    'not a patch',
    '{"op":"add","path":"/root","value":"missing"}',
    '{"op":"test","path":"/root","value":"x"}',
    block(element('main', 'Marquee', { text: 'An unknown component' })),
    block(element('main', 'Stack', {}, ['rows']), element('rows', 'Table', { rows: [] })),
    block(element('main', 'Text', { text: { $state: '/missing' } }))
  ]) {
    expectSource(invalid)
  }
})

test('conditional `$cond` props render the active branch and reject invalid inactive branches', () => {
  const validCond = block(
    statePatch('region', 'east'),
    element('main', 'Stat', {
      label: { $cond: { $state: '/region', eq: 'east' }, $then: 'East KPI', $else: 'West KPI' },
      value: { $cond: { $state: '/region', eq: 'east' }, $then: '1.28M', $else: '0.94M' }
    })
  )
  expect(markup(validCond)).toContain('East KPI')
  expect(markup(validCond)).toContain('1.28M')

  // An `$else` branch with the wrong prop type or missing state fails settled compilation immediately.
  const brokenElse = block(
    statePatch('region', 'east'),
    element('main', 'Stat', {
      label: { $cond: { $state: '/region', eq: 'east' }, $then: 'East KPI', $else: { $state: '/missing' } },
      value: '1.28M'
    })
  )
  expectSource(brokenElse)

  // Nested `$cond` combinations where only one mixed branch produces an invalid React child are also caught.
  const nestedBrokenCond = block(
    statePatch('a', true),
    statePatch('b', true),
    element('main', 'Text', {
      text: {
        $cond: { $state: '/a' },
        $then: 'Primary',
        $else: {
          $cond: { $state: '/b' },
          $then: { invalidReactChild: true },
          $else: 'Fallback'
        }
      }
    })
  )
  expectSource(nestedBrokenCond)
})

test('a block rejects deep JSON nesting, prototype-pollution segments, and sparse array indices', () => {
  let deep: unknown = 'leaf'
  for (let i = 0; i < 35; i++) {
    deep = { $cond: { $state: '/flag' }, $then: deep, $else: 'fallback' }
  }
  const tooDeep = block(statePatch('flag', true), element('main', 'Text', { text: deep }))
  expectSource(tooDeep)

  expectSource(
    [ROOT, '{"op":"add","path":"/state/__proto__/polluted","value":true}', element('main', 'Text', { text: 'x' })].join(
      '\n'
    )
  )
  expectSource(
    [
      ROOT,
      '{"op":"add","path":"/state/constructor/polluted","value":true}',
      element('main', 'Text', { text: 'x' })
    ].join('\n')
  )
  expectSource(
    [ROOT, '{"op":"add","path":"/state/items/5000","value":"sparse"}', element('main', 'Text', { text: 'x' })].join(
      '\n'
    )
  )
  expectSource('{"op":"add","path":"/","value":"root-overwrite"}')
  expectSource(block(element('main', 'Text', { text: { $state: 'missing_slash' } })))
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

test('a block validates action names and parameters and strips confirmation or navigation hooks', () => {
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
  expect(markup(press({ action: 'setState', params: { statePath: '/open', value: null } }))).toContain('Continue')
  expect(markup(press({ action: 'setState', params: { statePath: '/count', value: 3 } }))).toContain('Continue')

  // Malformed parameters, non-scalar `setState` values, and array-index pointers fall back to source instead.
  expectSource(press({ action: 'reply' }))
  expectSource(press({ action: 'reply', params: { message: 'Wrong key' } }))
  expectSource(press({ action: 'setState', params: { path: '/open', value: true } }))
  expectSource(press({ action: 'setState', params: { statePath: 'open', value: true } }))
  expectSource(press({ action: 'setState', params: { statePath: '/open' } }))
  expectSource(press({ action: 'setState', params: { statePath: '/open', value: { nested: true } } }))
  expectSource(press({ action: 'setState', params: { statePath: '/open', value: [1, 2, 3] } }))
  expectSource(press({ action: 'setState', params: { statePath: '/items/0', value: 'row' } }))
  expectSource(press({ action: 'setState', params: { statePath: '/items/999/expanded', value: true } }))
  expectSource(press({ action: 'setState', params: { statePath: '/items/-', value: 'row' } }))

  // The actions of Ankole's own cards and the rest of json-render's built-in actions are not block actions.
  for (const action of ['answer_choice', 'submit_form', 'resolve', 'pushState', 'removeState', 'validateForm']) {
    expectSource(press({ action, params: {} }))
  }
})

test('setState cannot overwrite repeat arrays, and empty repeat arrays still validate static props and actions', () => {
  // Overwriting a repeat pointer (directly, via an ancestor, or via nested `$item`) is rejected at compile time.
  expectSource(
    block(
      statePatch('items', [{ id: '1', label: 'One' }]),
      element('main', 'Stack', {}, ['btn', 'list']),
      element('btn', 'Button', { label: 'Clobber' }, [], {
        on: { press: { action: 'setState', params: { statePath: '/items', value: 'not-an-array' } } }
      }),
      element('list', 'Stack', {}, ['row'], { repeat: { statePath: '/items', key: 'id' } }),
      element('row', 'Text', { text: { $item: 'label' } })
    )
  )
  expectSource(
    block(
      statePatch('nested', { items: [{ id: '1', label: 'One' }] }),
      element('main', 'Stack', {}, ['btn', 'list']),
      element('btn', 'Button', { label: 'Clobber parent' }, [], {
        on: { press: { action: 'setState', params: { statePath: '/nested', value: 'scalar' } } }
      }),
      element('list', 'Stack', {}, ['row'], { repeat: { statePath: '/nested/items', key: 'id' } }),
      element('row', 'Text', { text: { $item: 'label' } })
    )
  )
  expectSource(
    block(
      statePatch('groups', [{ id: 'g1', children: ['a'] }]),
      element('main', 'Stack', {}, ['groupBtn', 'nestedList'], { repeat: { statePath: '/groups', key: 'id' } }),
      element('groupBtn', 'Button', { label: 'Clobber nested' }, [], {
        on: { press: { action: 'setState', params: { statePath: { $item: 'children' }, value: 'scalar' } } }
      }),
      element('nestedList', 'Stack', {}, ['leaf'], { repeat: { statePath: { $item: 'children' } } }),
      element('leaf', 'Text', { text: { $item: '' } })
    )
  )
  expectSource(
    block(
      statePatch('items', [{ id: '1', label: 'One' }]),
      element('main', 'Stack', {}, ['btn'], { repeat: { statePath: '/items', key: 'id' } }),
      element('btn', 'Button', { label: 'Overwrite item' }, [], {
        on: { press: { action: 'setState', params: { statePath: { $item: '' }, value: 'scalar' } } }
      })
    )
  )
  expectSource(
    block(
      statePatch('items', [{ id: '1', label: 'One' }]),
      element('main', 'Stack', {}, ['btn'], { repeat: { statePath: '/items', key: 'id' } }),
      element('btn', 'Button', { label: 'Numeric item path' }, [], {
        on: { press: { action: 'setState', params: { statePath: { $item: '0' }, value: 'scalar' } } }
      })
    )
  )

  // Empty repeat (`items: []`) still rejects invalid static props and invalid action params.
  expectSource(
    block(
      statePatch('items', []),
      element('main', 'Stack', {}, ['row'], { repeat: { statePath: '/items' } }),
      element('row', 'Text', { text: 12345 })
    )
  )
  expectSource(
    block(
      statePatch('items', []),
      element('main', 'Stack', {}, ['btn'], { repeat: { statePath: '/items' } }),
      element('btn', 'Button', { label: 'Bad path' }, [], {
        on: { press: { action: 'setState', params: { statePath: 'missing-slash', value: true } } }
      })
    )
  )
  expectSource(
    block(
      statePatch('items', []),
      element('main', 'Stack', {}, ['btn'], { repeat: { statePath: '/items' } }),
      element('btn', 'Button', { label: 'Bad reply' }, [], {
        on: { press: { action: 'reply', params: { text: 12345 } } }
      })
    )
  )
})

test('a block renders repeated item templates within the element budget and isolates interaction elements, watch and slots', () => {
  const repeated = block(
    statePatch('regions', [
      { id: 'east', name: 'East', revenue: '$1.28M' },
      { id: 'west', name: 'West', revenue: '$0.94M' }
    ]),
    element('main', 'Grid', { columns: 2 }, ['card'], { repeat: { statePath: '/regions', key: 'id' } }),
    element('card', 'Card', { title: { $item: 'name' } }, ['figure', 'ask']),
    element('figure', 'Text', { text: { $item: 'revenue' } }),
    element('ask', 'Button', { label: { $template: 'Inspect ${name}' } }, [], {
      on: { press: { action: 'reply', params: { text: { $template: 'Inspect ${name}' } } } }
    })
  )
  const repeatedHtml = markup(repeated)
  expect(repeatedHtml).toContain('East')
  expect(repeatedHtml).toContain('$1.28M')
  expect(repeatedHtml).toContain('Inspect West')

  // Repeating 200 items of 3 elements (1 + 600 > 500) trips the element budget.
  const manyItems = Array.from({ length: 200 }, (_, i) => ({ id: `r-${i}`, name: `R${i}`, revenue: '1' }))
  const overBudgetRepeat = block(
    statePatch('regions', manyItems),
    element('main', 'Stack', {}, ['card'], { repeat: { statePath: '/regions', key: 'id' } }),
    element('card', 'Card', { title: { $item: 'name' } }, ['figure', 'extra']),
    element('figure', 'Text', { text: { $item: 'revenue' } }),
    element('extra', 'Text', { text: 'unit' })
  )
  expectSource(overBudgetRepeat)

  // Invalid repeat targets, leaf repeats, and `$item` outside repeat fail validation.
  const item = element('item', 'Text', { text: 'x' })
  expectSource(block(element('main', 'Stack', {}, ['item'], { repeat: { statePath: '/missing' } }), item))
  expectSource(
    block(
      statePatch('scalar', 'nope'),
      element('main', 'Stack', {}, ['item'], { repeat: { statePath: '/scalar' } }),
      item
    )
  )
  expectSource(
    block(statePatch('items', [1]), element('main', 'Text', { text: 'x' }, [], { repeat: { statePath: '/items' } }))
  )
  expectSource(block(element('main', 'Text', { text: { $item: 'name' } })))

  // Interaction surface elements, `watch`, and named `slots` remain unreachable.
  expectSource(
    block(
      element('main', 'InteractionCard', { kind: 'approval', title: 'Approval required', state: 'pending' }, ['go']),
      element('go', 'ActionButton', { label: 'Confirm', variant: 'default', size: 'sm', disabled: false })
    )
  )
  for (const type of ['Choice', 'QuickAnswer', 'FormField', 'Outcome', 'PageLink', 'Disclosure']) {
    expectSource(block(element('main', 'Stack', {}, ['inner']), element('inner', type, { label: 'x', text: 'x' })))
  }
  expectSource(
    block(
      element('main', 'Stack', {}, ['item'], {
        watch: { '/x': { action: 'setState', params: { statePath: '/y', value: 1 } } }
      }),
      item
    )
  )
  expectSource(block(element('main', 'Stack', {}, [], { slots: { header: ['item'] } }), item))
})

test('every catalog component renders from a spec, formats numeric table columns, and sets appropriate alert roles', () => {
  const rows = [
    { team: 'Alpha', open: 1280000, rate: 0.125, done: 3000 },
    { team: 'Beta', open: 940000, rate: 0.08, done: null }
  ]
  const children = ['picker', 'tabs', 'details', 'note', 'warn', 'progress', 'badge', 'chart']
  const code = block(
    statePatch('dept', 'eng'),
    element('main', 'Stack', { gap: 'lg' }, children),
    element('picker', 'Select', {
      label: 'Department',
      options: [
        { value: 'eng', label: 'Engineering' },
        { value: 'ops', label: 'Operations' }
      ],
      value: { $bindState: '/dept' }
    }),
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
        { key: 'open', label: 'Volume', align: 'end', format: 'compact' },
        { key: 'rate', label: 'Share', align: 'end', format: 'percent' },
        { key: 'done', label: 'Done', align: 'end', format: 'number' }
      ],
      rows,
      sortable: true
    }),
    element('details', 'Accordion', {}, ['method']),
    element('method', 'AccordionItem', { title: 'How this was counted' }, []),
    element('note', 'Alert', { title: 'Info', text: 'Counts refresh per turn' }),
    element('warn', 'Alert', { title: 'Heads up', text: 'Beta has no finished work yet', variant: 'warning' }),
    element('progress', 'Progress', { label: 'Sprint', value: 40 }),
    element('badge', 'Badge', { text: 'On track', variant: 'success' }),
    element('chart', 'Chart', { type: 'column', data: rows, xField: 'team', yField: 'open', title: 'Open by team' })
  )
  const used = new Set(Object.values(compileUIBlock(code)!.elements).map(item => item.type))
  // The reference example covers the two components that this spec leaves out.
  expect([...used, 'Button', 'ToggleGroup'].sort()).toEqual([...uiBlockCatalog.componentNames].sort())
  const html = markup(code)
  for (const text of [
    'Engineering',
    'Numbers',
    'By team',
    'Open issues',
    'Scope',
    'Two teams',
    '1.28M',
    '940K',
    '12.5%',
    '3,000',
    'How this was counted',
    'Heads up',
    'Sprint',
    'On track',
    'role="status"',
    'role="alert"'
  ]) {
    expect(html).toContain(text)
  }
})

test('switchers seed unset bound state paths to their first option, and standalone Tabs remember the open tab', () => {
  // No `/state/region` line is present; `ToggleGroup` seeds `/region` to `'east'` so the first view is visible.
  const unseededToggle = block(
    element('main', 'Stack', {}, ['east', 'west', 'toggle']),
    element('east', 'Text', { text: 'East summary' }, [], { visible: { $state: '/region', eq: 'east' } }),
    element('west', 'Text', { text: 'West summary' }, [], { visible: { $state: '/region', eq: 'west' } }),
    element('toggle', 'ToggleGroup', {
      options: [
        { value: 'east', label: 'East' },
        { value: 'west', label: 'West' }
      ],
      value: { $bindState: '/region' }
    })
  )
  expect(markup(unseededToggle)).toContain('East summary')
  expect(markup(unseededToggle)).not.toContain('West summary')

  // Standalone `Tabs` bind into `__tabs/<key>`, so `rememberViewState` restores the active tab on remount.
  const tabbed = block(
    element(
      'main',
      'Tabs',
      {
        tabs: [
          { value: 'first', label: 'First Tab' },
          { value: 'second', label: 'Second Tab' }
        ]
      },
      ['p1', 'p2']
    ),
    element('p1', 'TabPanel', { value: 'first' }, ['t1']),
    element('t1', 'Text', { text: 'One' }),
    element('p2', 'TabPanel', { value: 'second' }, ['t2']),
    element('t2', 'Text', { text: 'Two' })
  )
  const compiledTabs = compileUIBlock(tabbed)!
  expect(compiledTabs.state).toEqual({ __tabs: { main: 'first' } })
  expect(markup(tabbed)).toMatch(/aria-selected="true"[^>]*>First Tab<\/button>/)
  rememberViewState(tabbed, { __tabs: { main: 'second' } })
  const restored = markup(tabbed)
  expect(restored).toMatch(/aria-selected="true"[^>]*>Second Tab<\/button>/)

  // A null intermediate state segment never crashes switcher seeding.
  const nullParent = block(
    statePatch('nested', null),
    element('main', 'Select', {
      options: [{ value: 'a', label: 'Option A' }],
      value: { $bindState: '/nested/choice' }
    })
  )
  expect(markup(nullParent)).toContain('Option A')
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

test('a settled block that mounts again shows what its reader left, and a streaming block starts fresh', () => {
  // A block of its own, so the state remembered here stays out of the other tests.
  const customBlock = example.replace('East revenue', 'Eastern revenue')
  expect(markup(customBlock)).toContain('Eastern revenue')
  rememberViewState(customBlock, { region: 'west' })
  const again = markup(customBlock)
  expect(again).toContain('West revenue')
  expect(again).not.toContain('Eastern revenue')
  expect(markup(customBlock, true)).toContain('Eastern revenue')
})

test('remembered state validates once on restore and falls back to spec.state instead of degrading to source', () => {
  const repeatBlock = block(
    statePatch('items', [{ label: 'Initial row' }]),
    element('main', 'Stack', {}, ['list']),
    element('list', 'Stack', {}, ['row'], { repeat: { statePath: '/items' } }),
    element('row', 'Text', { text: { $item: 'label' } })
  )
  const spec = compileUIBlock(repeatBlock)!
  expect(validateUIBlockState(spec, { items: [{ label: 'One' }, { label: 'Two' }] })).toBe(true)

  // Stale or corrupted remembered state exceeding the 500-element budget is discarded in favor of `spec.state`.
  const sixHundred = Array.from({ length: 600 }, (_, i) => ({ label: `Row ${i}` }))
  expect(validateUIBlockState(spec, { items: sixHundred })).toBe(false)
  rememberViewState(repeatBlock, { items: sixHundred })
  const recoveredHtml = markup(repeatBlock)
  expect(recoveredHtml).toContain('chat-ui-block')
  expect(recoveredHtml).toContain('Initial row')
  expect(recoveredHtml).not.toContain('pod-chat-code-body')

  // Nested repeat amplification (25 groups x 25 children > 500) and non-array repeat state are also rejected.
  const nestedRepeatBlock = block(
    statePatch('groups', []),
    element('main', 'Stack', {}, ['group'], { repeat: { statePath: '/groups' } }),
    element('group', 'Stack', {}, ['leaf'], { repeat: { statePath: { $item: 'children' } } }),
    element('leaf', 'Text', { text: { $item: '' } })
  )
  const nestedSpec = compileUIBlock(nestedRepeatBlock)!
  const amplifiedGroups = Array.from({ length: 25 }, () => ({
    children: Array.from({ length: 25 }, (_, j) => `Item ${j}`)
  }))
  expect(validateUIBlockState(nestedSpec, { groups: amplifiedGroups })).toBe(false)
  expect(validateUIBlockState(spec, { items: 'not-an-array' })).toBe(false)
  expect(validateUIBlockState(spec, { items: [{ label: { bad: 1 } }] })).toBe(false)
})

test('streamed repeat templates keep only children ready across every item, and state validation propagates child pending', () => {
  const partialNested = block(
    statePatch('groups', [
      { id: 'g1', title: 'Group One' },
      { id: 'g2', title: 'Group Two', tabs: [{ value: 'overview', label: 'Overview' }] }
    ]),
    element('main', 'Stack', {}, ['group'], { repeat: { statePath: '/groups', key: 'id' } }),
    element('group', 'Card', { title: { $item: 'title' } }, ['groupTabs']),
    element('groupTabs', 'Tabs', { tabs: { $item: 'tabs' } }, ['panel']),
    element('panel', 'TabPanel', { value: 'overview' }, ['leaf']),
    element('leaf', 'Text', { text: 'Ready panel' })
  )

  const streamedSpec = compileUIBlock(partialNested, true)!
  expect(streamedSpec.elements.group!.children).toEqual([])
  expect(streamedSpec.elements.groupTabs).toBeUndefined()
  const streamedHtml = markup(partialNested, true)
  expect(streamedHtml).toContain('Group One')
  expect(streamedHtml).toContain('Group Two')
  expect(streamedHtml).not.toContain('Ready panel')

  // Even when a pre-compiled spec still lists `groupTabs`, state validation during streaming rejects missing item props.
  const fullNested = block(
    statePatch('groups', [
      { id: 'g1', title: 'Group One', tabs: [{ value: 'overview', label: 'Overview' }] },
      { id: 'g2', title: 'Group Two', tabs: [{ value: 'overview', label: 'Overview' }] }
    ]),
    element('main', 'Stack', {}, ['group'], { repeat: { statePath: '/groups', key: 'id' } }),
    element('group', 'Card', { title: { $item: 'title' } }, ['groupTabs']),
    element('groupTabs', 'Tabs', { tabs: { $item: 'tabs' } }, ['panel']),
    element('panel', 'TabPanel', { value: 'overview' }, ['leaf']),
    element('leaf', 'Text', { text: 'Ready panel' })
  )
  const fullSpec = compileUIBlock(fullNested)!
  expect(
    validateUIBlockState(
      fullSpec,
      {
        groups: [
          { id: 'g1', title: 'Group One' },
          { id: 'g2', title: 'Group Two', tabs: [{ value: 'overview', label: 'Overview' }] }
        ]
      },
      true
    )
  ).toBe(false)
})

test('tables with per-row `$cond` expressions validate in linear time without Cartesian branch caps', () => {
  const columns = [
    { key: 'service', label: 'Service' },
    { key: 'status', label: 'Status' }
  ]
  const rows = Array.from({ length: 20 }, (_, i) => ({
    service: `svc-${i}`,
    status: { $cond: { $state: '/verbose' }, $then: `Healthy (${i})`, $else: 'OK' }
  }))
  const tableBlock = block(statePatch('verbose', false), element('main', 'Table', { columns, rows }))
  expect(compileUIBlock(tableBlock)).toBeDefined()
  const html = markup(tableBlock)
  expect(html).toContain('svc-0')
  expect(html).toContain('svc-19')
  expect(html).toContain('OK')

  const brokenRowRows = rows.map((row, idx) =>
    idx === 12
      ? {
          service: row.service,
          status: { $cond: { $state: '/verbose' }, $then: { invalidCell: true }, $else: 'OK' }
        }
      : row
  )
  expectSource(block(statePatch('verbose', false), element('main', 'Table', { columns, rows: brokenRowRows })))
})

test('action parameters distinguish `setState.statePath` addresses from `$item` data values at compile and click time', () => {
  const items = [{ id: 'alpha', label: 'Actual name', count: 42, expanded: false }]
  const code = block(
    statePatch('items', items),
    statePatch('selected', ''),
    element('main', 'Stack', {}, ['replyBtn', 'selectBtn', 'toggleBtn'], {
      repeat: { statePath: '/items', key: 'id' }
    }),
    element('replyBtn', 'Button', { label: { $item: 'label' } }, [], {
      on: { press: { action: 'reply', params: { text: { $item: 'label' } } } }
    }),
    element('selectBtn', 'Button', { label: 'Select' }, [], {
      on: { press: { action: 'setState', params: { statePath: '/selected', value: { $item: 'label' } } } }
    }),
    element('toggleBtn', 'Button', { label: 'Toggle' }, [], {
      on: { press: { action: 'setState', params: { statePath: { $item: 'expanded' }, value: true } } }
    })
  )

  const spec = compileUIBlock(code)!
  const liveCtx = {
    stateModel: spec.state!,
    repeatItem: items[0],
    repeatIndex: 0,
    repeatBasePath: '/items/0'
  }

  const replyBinding = (spec.elements.replyBtn!.on!.press as Array<{ params: Record<string, unknown> }>)[0]!
  expect(resolveActionParam(replyBinding.params.text, liveCtx)).toBe('Actual name')

  const selectBinding = (spec.elements.selectBtn!.on!.press as Array<{ params: Record<string, unknown> }>)[0]!
  expect(resolveActionParam(selectBinding.params.statePath, liveCtx)).toBe('/selected')
  expect(resolveActionParam(selectBinding.params.value, liveCtx)).toBe('Actual name')

  const toggleBinding = (spec.elements.toggleBtn!.on!.press as Array<{ params: Record<string, unknown> }>)[0]!
  expect(resolveActionParam(toggleBinding.params.statePath, liveCtx)).toBe('/items/0/expanded')
  expect(resolveActionParam(toggleBinding.params.value, liveCtx)).toBe(true)

  // Non-string `$item` field in `reply.params.text` is rejected rather than coerced to `/items/0/count`.
  const badReply = block(
    statePatch('items', items),
    element('main', 'Stack', {}, ['badBtn'], { repeat: { statePath: '/items', key: 'id' } }),
    element('badBtn', 'Button', { label: 'Ask' }, [], {
      on: { press: { action: 'reply', params: { text: { $item: 'count' } } } }
    })
  )
  expectSource(badReply)
})

test('a block that Pod cannot use says which part failed and why', () => {
  expect(explainUIBlockFailure(block(element('main', 'Text', { text: 'Hi' })))).toBeUndefined()
  expect(explainUIBlockFailure('not a patch')).toEqual({ code: 'invalid_line', path: '', detail: 'line 1' })
  expect(explainUIBlockFailure(ROOT)).toEqual({ code: 'missing_root', path: '/root' })
  expect(
    explainUIBlockFailure([ROOT, '{"op":"add","path":"/state/__proto__/polluted","value":true}'].join('\n'))
  ).toEqual({ code: 'unsafe_patch', path: '/state/__proto__/polluted', detail: 'line 2' })
  expect(explainUIBlockFailure(block(element('main', 'Marquee', { text: 'Unknown' })))).toEqual({
    code: 'unknown_component',
    path: '/elements/main/type',
    detail: 'Marquee'
  })
  expect(explainUIBlockFailure(block(element('main', 'Stack', {}, ['rows'])))).toEqual({
    code: 'missing_element',
    path: '/elements/rows'
  })
  expect(explainUIBlockFailure(block(element('main', 'Stack', {}, ['main'])))).toEqual({
    code: 'cycle',
    path: '/elements/main'
  })
  expect(
    explainUIBlockFailure(
      block(element('main', 'Button', { label: 'Go' }, [], { on: { press: { action: 'navigate', params: {} } } }))
    )
  ).toEqual({ code: 'invalid_action', path: '/elements/main/on' })
  // The path of a rejected prop leads to the value that the component schema refuses.
  expect(
    explainUIBlockFailure(block(element('main', 'Table', { columns: [{ key: 'team', label: 1 }], rows: [] })))
  ).toMatchObject({ code: 'invalid_props', path: '/elements/main/props/columns/0/label' })
  expect(explainUIBlockFailure(block(element('main', 'Text', { text: { $state: '/missing' } })))).toMatchObject({
    code: 'invalid_props',
    path: '/elements/main/props/text'
  })
  // The path of a prop that reads state continues into the value that the state holds.
  expect(
    explainUIBlockFailure(
      block(
        statePatch('rows', [{ team: { nested: true } }]),
        element('main', 'Table', { columns: [{ key: 'team', label: 'Team' }], rows: { $state: '/rows' } })
      )
    )
  ).toMatchObject({ code: 'invalid_props', path: '/elements/main/props/rows/0/team' })

  const text = (rest: object) => block(element('main', 'Text', { text: 'x' }, [], rest))
  const many = Array.from({ length: 500 }, (_, index) => `item${index}`)
  for (const [source, failure] of [
    [[ROOT, '{"op":"test","path":"/root","value":"other"}'].join('\n'), { code: 'invalid_patch', path: '/root' }],
    [
      block(element('main', 'Stack', {}, many), ...many.map(key => element(key, 'Text', { text: key }))),
      { code: 'over_budget', path: '/elements/item499' }
    ],
    [block('{"op":"add","path":"/elements/main","value":"Text"}'), { code: 'invalid_element', path: '/elements/main' }],
    [text({ watch: {} }), { code: 'unsupported_field', path: '/elements/main/watch' }],
    [text({ repeat: { statePath: '/rows' } }), { code: 'invalid_repeat', path: '/elements/main/repeat' }],
    [text({ visible: { $unknown: true } }), { code: 'invalid_visible', path: '/elements/main/visible' }],
    [
      block(element('main', 'Text', { text: { $computed: 'now' } })),
      { code: 'invalid_expression', path: '/elements/main/props' }
    ]
  ] as const) {
    expect(explainUIBlockFailure(source)).toMatchObject(failure)
  }
})

test('an element may leave out empty `props` and `children`', () => {
  const lean = [
    ROOT,
    '{"op":"add","path":"/elements/main","value":{"type":"Stack","children":["note"]}}',
    '{"op":"add","path":"/elements/note","value":{"type":"Text","props":{"text":"Lean line"}}}'
  ].join('\n')
  expect(markup(lean)).toContain('Lean line')
  expect(compileUIBlock(lean)!.elements.main).toMatchObject({ props: {}, children: ['note'] })
})

test('a table and a chart read the same rows from state, and appended rows show while the block streams', () => {
  // The reference teaches this pattern with its own example, which has to stay a usable block.
  expect(examples).toHaveLength(2)
  expect(markup(examples[1]!)).toContain('Alpha')

  const lines = [
    ROOT,
    statePatch('rows', []),
    element('main', 'Stack', {}, ['table', 'chart']),
    element('table', 'Table', {
      columns: [
        { key: 'team', label: 'Team' },
        { key: 'revenue', label: 'Revenue', align: 'end' }
      ],
      rows: { $state: '/rows' }
    }),
    element('chart', 'Chart', { type: 'column', data: { $state: '/rows' }, xField: 'team', yField: 'revenue' }),
    '{"op":"add","path":"/state/rows/-","value":{"team":"Alpha","revenue":12}}',
    '{"op":"add","path":"/state/rows/-","value":{"team":"Beta","revenue":7}}'
  ]
  const settled = lines.join('\n')
  expect(compileUIBlock(settled)!.state).toEqual({
    rows: [
      { team: 'Alpha', revenue: 12 },
      { team: 'Beta', revenue: 7 }
    ]
  })
  expect(markup(settled)).toContain('Alpha')
  expect(markup(settled)).toContain('Beta')

  // Each appended row is its own line, so the table grows while the block streams.
  const empty = markup(lines.slice(0, 5).join('\n'), true)
  expect(empty).toContain('Team')
  expect(empty).not.toContain('Alpha')
  const oneRow = markup([...lines.slice(0, 6), lines[6]!.slice(0, 40)].join('\n'), true)
  expect(oneRow).toContain('Alpha')
  expect(oneRow).not.toContain('Beta')
})

test('a settled block of a reply reaches the listeners once, and an unusable block leaves its reason in the console', () => {
  const usable = block(element('main', 'Text', { text: 'Counted once' }))
  const unusable = block(element('main', 'Marquee', { text: 'Counted once' }))
  const failure = explainUIBlockFailure(unusable)!
  const warn = spyOn(console, 'warn').mockImplementation(() => {})
  const heard: UIBlockOutcome[] = []
  const listener = (outcome: UIBlockOutcome) => void heard.push(outcome)

  try {
    // With no listener, Pod keeps no record, so a listener that registers later still hears the block.
    recordUIBlockOutcome(usable, undefined, 'signal-1')
    uiBlockOutcomeListeners.add(listener)

    recordUIBlockOutcome(usable, undefined, 'signal-1')
    recordUIBlockOutcome(usable, undefined, 'signal-1')
    // The same block in another reply is another block, and a copy outside a reply carries no Signal to report.
    recordUIBlockOutcome(usable, undefined, 'signal-2')
    recordUIBlockOutcome(usable, undefined, undefined)
    recordUIBlockOutcome(unusable, failure, 'signal-3')
    recordUIBlockOutcome(unusable, failure, undefined)
    expect(heard).toEqual([{ signalID: 'signal-1' }, { signalID: 'signal-2' }, { failure, signalID: 'signal-3' }])
    expect(warn.mock.calls).toEqual([
      ['[Ankole] A ui block is shown as code', failure],
      ['[Ankole] A ui block is shown as code', failure]
    ])

    // The page remembers its 200 most recent reports, so the oldest block is heard again after 200 others.
    for (let index = 0; index < 200; index++) recordUIBlockOutcome(usable, undefined, `later-${index}`)
    heard.length = 0
    recordUIBlockOutcome(usable, undefined, 'later-199')
    recordUIBlockOutcome(usable, undefined, 'signal-1')
    expect(heard).toEqual([{ signalID: 'signal-1' }])

    uiBlockOutcomeListeners.delete(listener)
    recordUIBlockOutcome(usable, undefined, 'after-the-listener-left')
    expect(heard).toHaveLength(1)
  } finally {
    uiBlockOutcomeListeners.delete(listener)
    warn.mockRestore()
  }
})
