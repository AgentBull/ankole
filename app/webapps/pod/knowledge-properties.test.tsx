import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import { KnowledgeProperties } from './knowledge-properties'
import { KnowledgeValue } from './knowledge-value'
import { KnowledgeDraftModel } from './state/knowledge-draft'

test('property values read as chips and key: value lines instead of raw brackets', () => {
  const markup = renderToStaticMarkup(
    <KnowledgeValue value={{ owners: ['alice', 'bob'], limits: { daily: 3 }, steps: [{ name: 'draft' }] }} />
  )
  expect(markup.replace(/<[^>]*>/g, '')).not.toMatch(/[[\]{}]/)
  expect(markup).toContain('data-slot="badge"')
  expect(markup).toContain('>alice</span>')
  expect(markup).toContain('owners: </span>')
  expect(markup).toContain('daily: </span>3')
  expect(markup).toContain('role="listitem"')
})

test('property errors are localized and a YAML error names its line and column', async () => {
  await loadLocale('en-US')
  const draft = new KnowledgeDraftModel()
  draft.begin({ summary: 'Before' })
  draft.change(0, { source: 'ok: 1\nbad: [' })
  // Interpolated names arrive inside bidi isolates.
  const render = () =>
    renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <KnowledgeProperties metadata={{}} draft={draft} />
      </I18nextProvider>
    ).replace(/[\u2068\u2069]/g, '')
  expect(render()).toContain('The value of summary has a YAML syntax error at line 2, column 7.')
  draft.change(0, { source: 'Before' })
  draft.add()
  expect(render()).toContain('Enter a name for every property.')
  draft.change(1, { key: 'summary' })
  expect(render()).toContain('More than one property is named summary.')
})
