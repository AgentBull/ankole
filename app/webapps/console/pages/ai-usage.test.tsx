import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { CapabilityTable, UsageTable } from './ai-usage'

test('a usage table takes its accessible name from its heading', async () => {
  await loadLocale('en-US')
  const row = { key: 'sales-bot', name: 'Sales Bot', rounds: 2, reported_rounds: 2 } as never
  const html = renderToStaticMarkup(
    <I18nextProvider i18n={i18n.cloneInstance({ lng: 'en-US', initAsync: false })}>
      <UsageTable title="By Agent" rows={[row]} label={() => 'Sales Bot'} />
    </I18nextProvider>
  )

  const headingID = html.match(/<h3 id="([^"]+)"[^>]*>By Agent<\/h3>/)?.[1]
  expect(headingID).toBeDefined()
  expect(html).toMatch(new RegExp(`<table [^>]*aria-labelledby="${headingID}"`))
})

test('the capability table names each capability and unit and leaves unreported values blank', async () => {
  await loadLocale('en-US')
  const html = renderToStaticMarkup(
    <I18nextProvider i18n={i18n.cloneInstance({ lng: 'en-US', initAsync: false })}>
      <CapabilityTable
        rows={[
          { capability: 'ocr', unit: 'page', calls: 2, quantity: 15, provider_cost: null },
          { capability: 'transcription', unit: 'second', calls: 2, quantity: 1500, provider_cost: 0.000808 },
          { capability: 'decision', unit: null, calls: 1, quantity: null, provider_cost: null }
        ]}
      />
    </I18nextProvider>
  )
  const cells = [...html.matchAll(/<td[^>]*>(.*?)<\/td>/g)].map(match => match[1])

  expect(cells).toEqual(
    [
      ['OCR', '2', '15', 'Pages', '—'],
      ['Transcription', '2', '1,500', 'Seconds of audio', '0.000808'],
      ['Decision model', '1', '—', '—', '—']
    ].flat()
  )
})
