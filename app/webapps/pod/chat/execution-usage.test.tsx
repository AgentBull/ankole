import { beforeAll, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { CollapsedWorkView } from './collapsed-work-view'
import type { ExecutionUsage } from './types'

beforeAll(() => loadLocale('en-US'))

const reported: ExecutionUsage = {
  rounds: 3,
  reported_rounds: 3,
  input_tokens: 12_000,
  output_tokens: 400,
  cached_input_tokens: 8_000,
  reasoning_tokens: null,
  models: [
    {
      model: 'openai/gpt-5.5',
      model_profile: 'light',
      served_profile: 'primary',
      rounds: 3,
      reported_rounds: 3,
      input_tokens: 12_000,
      output_tokens: 400,
      cached_input_tokens: 8_000,
      reasoning_tokens: null
    }
  ]
}

// Interpolated values carry Unicode isolation marks and adjacent text nodes carry
// markers; the assertions read the visible text.
function render(usage: ExecutionUsage) {
  return renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <CollapsedWorkView execution={{ duration_ms: 2_000, steps: [], usage }} attention />
    </I18nextProvider>
  )
    .replace(/[\u2068\u2069]/g, '')
    .replaceAll('<!-- -->', '')
}

test('a reply without tools still shows its model and tokens, and the fallback it used', () => {
  const html = render(reported)
  expect(html).toContain('Worked for')
  expect(html).toContain('gpt-5.5 · 12.4K tokens')
  expect(html).toContain('light → primary')
  expect(html).toContain('Reasoning —')
})

test('a model that did not always report says so, and other models are named', () => {
  const partial = { ...reported.models[0], reported_rounds: 1 }
  const vision = { ...reported.models[0], model: 'openai/vision', model_profile: undefined, rounds: 1 }
  const html = render({ ...reported, reported_rounds: 2, models: [partial, vision] })
  expect(html).toContain('1/3 reported')
  expect(html).toContain('title="vision"')
  expect(html).toContain('Also used: vision')
})

test('unreported rounds are named instead of counted as zero', () => {
  expect(render({ ...reported, reported_rounds: 1 })).toContain('≥12.4K tokens (2 rounds not reported)')
  expect(render({ ...reported, reported_rounds: 0, input_tokens: null, output_tokens: null })).toContain(
    'Usage not reported'
  )
})
