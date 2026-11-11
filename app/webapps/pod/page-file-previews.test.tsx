import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import PdfPreview from './file-pdf'
import { DelimitedTablePreview } from './page-file-previews'

beforeAll(async () => {
  await loadLocale('en-US')
})

describe('DelimitedTablePreview', () => {
  test('renders parsed CSV and TSV headers, cells, and truncation download links', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
    const cacheKey = ['pod-page-file', 'page-1'] as const
    const csvUrl = '/api/v2/pod/pages/page-1/files/content?path=sales.csv'
    const tsvUrl = '/api/v2/pod/pages/page-1/files/content?path=metrics.tsv'

    client.setQueryData([...cacheKey, 'file-delimited-preview', csvUrl], {
      text: 'Region,Revenue\nNorth,"1,250"\nSouth,980\n',
      truncated: false
    })
    client.setQueryData([...cacheKey, 'file-delimited-preview', tsvUrl], {
      text: 'Metric\tValue\nGMV\t60.5\n',
      truncated: true
    })

    try {
      const csvHtml = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <DelimitedTablePreview cacheKey={cacheKey} url={csvUrl} name="sales.csv" canComment />
          </QueryClientProvider>
        </I18nextProvider>
      )
      expect(csvHtml).toContain('Region')
      expect(csvHtml).toContain('Revenue')
      expect(csvHtml).toContain('1,250')
      expect(csvHtml).toContain('data-csv-row="1"')
      expect(csvHtml).toContain('data-csv-row="2"')
      expect(csvHtml).not.toContain('data-testid="search-truncated-notice"')

      const tsvHtml = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <DelimitedTablePreview
              cacheKey={cacheKey}
              url={tsvUrl}
              name="metrics.tsv"
              canComment={false}
              initialAnchor={{ kind: 'csv_rows', start_row: 20, end_row: 22 }}
            />
          </QueryClientProvider>
        </I18nextProvider>
      )
      expect(tsvHtml).toContain('Metric')
      expect(tsvHtml).toContain('GMV')
      expect(tsvHtml).toContain('60.5')
      expect(tsvHtml).toContain('data-testid="search-truncated-notice"')
      expect(tsvHtml).toContain('download="metrics.tsv"')
    } finally {
      client.clear()
    }
  })

  test('renders an empty-state message when a delimited file has no columns or rows', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
    const cacheKey = ['pod-page-file', 'page-empty'] as const
    const url = '/api/v2/pod/pages/page-empty/files/content?path=empty.csv'
    client.setQueryData([...cacheKey, 'file-delimited-preview', url], { text: '', truncated: false })

    try {
      const html = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <DelimitedTablePreview cacheKey={cacheKey} url={url} name="empty.csv" canComment={false} />
          </QueryClientProvider>
        </I18nextProvider>
      )
      expect(html).not.toContain('<table')
    } finally {
      client.clear()
    }
  })
})

describe('PdfPreview', () => {
  test('renders accessible paging, search, zoom controls, and an undetermined-language scroll region while loading', () => {
    const html = renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <PdfPreview url="/api/v2/pod/pages/page-1/files/content?path=handbook.pdf" title="Handbook.pdf" />
      </I18nextProvider>
    )

    expect(html).toContain('aria-label="Handbook.pdf"')
    expect(html).toContain('lang="und"')
    expect(html).toContain(`aria-label="${i18n.t('pod.content.previous_page')}"`)
    expect(html).toContain(`aria-label="${i18n.t('pod.content.next_page')}"`)
    expect(html).toContain(`aria-label="${i18n.t('pod.content.find_in_page')}"`)
    expect(html).toContain(`aria-label="${i18n.t('pod.chat_timeline.zoom_out')}"`)
    expect(html).toContain(`aria-label="${i18n.t('pod.chat_timeline.zoom_in')}"`)
  })
})
