import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { UsageTable } from './ai-usage'

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
