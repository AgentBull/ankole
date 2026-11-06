import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import { ManagedAgent } from './pod-settings'

test('each Agent card and its actions name the Agent they act on', async () => {
  await loadLocale('en-US')
  const html = renderToStaticMarkup(
    <QueryClientProvider client={new QueryClient()}>
      <I18nextProvider i18n={i18n}>
        <ManagedAgent
          agent={{
            uid: 'sales-bot',
            displayName: 'Sales Bot',
            ownerUID: 'alice',
            status: 'active',
            type: 'ai_colleague'
          }}
          onSuccess={async () => {}}
        />
      </I18nextProvider>
    </QueryClientProvider>
  )

  const labelledBy = html.match(/role="group" aria-labelledby="([^"]+)"/)?.[1]
  expect(labelledBy).toBeDefined()
  expect(html).toContain(`<h2 id="${labelledBy}">Sales Bot</h2>`)
  // Interpolated values arrive wrapped in Unicode bidi isolates.
  expect(html).toContain('aria-label="Disable \u2068Sales Bot\u2069"')
  expect(html).toContain('aria-label="Rename UID of \u2068sales-bot\u2069"')
})
