import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import { codeLanguageFromFileName, isHtmlFile } from '../common/file-preview'
import i18n, { loadLocale } from '../common/i18n'
import { contentKeys } from './content-api'
import PdfPreview from './file-pdf'
import { buildSandboxedHtmlSrcDoc, HTML_SANDBOX_ALLOW, HtmlFilePreview } from './html-file-preview'
import { DelimitedTablePreview, FileSelectionToolbar, locatedRunClassName, TextFilePreview } from './page-file-previews'

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

describe('HTML and code source previews', () => {
  test('detects HTML variants and maps source file extensions to Shiki grammars', () => {
    expect(isHtmlFile('applet.html')).toBe(true)
    expect(isHtmlFile('legacy.htm')).toBe(true)
    expect(isHtmlFile('document (1).xhtml')).toBe(true)
    expect(isHtmlFile('bundle.bin', 'text/html; charset=utf-8')).toBe(true)
    expect(isHtmlFile('script.ts', 'text/plain')).toBe(false)

    expect(codeLanguageFromFileName('applet (2).htm')).toBe('html')
    expect(codeLanguageFromFileName('page.xhtml')).toBe('html')
    expect(codeLanguageFromFileName('router.exs')).toBe('elixir')
    expect(codeLanguageFromFileName('Dockerfile')).toBe('dockerfile')
    expect(codeLanguageFromFileName('notes.txt')).toBeUndefined()
  })

  test('injects the sandbox storage and external-link shim without breaking Standards Mode doctypes', () => {
    const withHead = buildSandboxedHtmlSrcDoc(
      '<!doctype html><html lang="zh"><head><title>App</title></head><body>Hi</body></html>'
    )
    expect(withHead.startsWith('<!doctype html><html lang="zh"><head><script>')).toBe(true)
    expect(withHead).toContain('localStorage')
    expect(withHead).toContain('<title>App</title>')

    const scriptWithLiteralHead = buildSandboxedHtmlSrcDoc(
      '<!DOCTYPE html><script>const x = "<head>"</script><h1>Demo</h1>'
    )
    expect(scriptWithLiteralHead.startsWith('<!DOCTYPE html><script>(function()')).toBe(true)
    expect(scriptWithLiteralHead).toContain('const x = "<head>"')

    const fragment = buildSandboxedHtmlSrcDoc('<h1>Fragment</h1>')
    expect(fragment.startsWith('<!doctype html><script>')).toBe(true)
    expect(fragment.endsWith('<h1>Fragment</h1>')).toBe(true)
  })

  test('defaults HTML files to an opaque-origin sandboxed iframe without truncation banners under 16 MiB', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
    const cacheKey = ['pod-page-file', 'page-html'] as const
    const url = '/api/v2/pod/pages/page-html/files/content?path=ankole-pod-page-applet.html'

    client.setQueryData([...cacheKey, 'file-html-preview', url, 'full'], {
      previewHtml: '<!doctype html><html><body><h1>Applet</h1></body></html>',
      sourceText: '<!doctype html>\n<html><body><h1>Applet</h1></body></html>',
      tooLarge: false,
      sourceTruncated: true,
      empty: false
    })

    try {
      const html = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <HtmlFilePreview
              cacheKey={cacheKey}
              url={url}
              name="ankole-pod-page-applet.html"
              size={3_500_000}
              canComment
              fileMeta={<span>ankole-pod-page-applet.html · 3.3 MB</span>}
            />
          </QueryClientProvider>
        </I18nextProvider>
      )

      expect(html).toContain('role="tablist"')
      expect(html).toContain(`sandbox="${HTML_SANDBOX_ALLOW}"`)
      expect(html).not.toContain('allow-same-origin')
      expect(html).toContain('referrerPolicy="no-referrer"')
      expect(html).toContain(`aria-label="${i18n.t('pod.content.reload_preview')}"`)
      expect(html).toContain(`aria-label="${i18n.t('pod.content.full_screen_preview')}"`)
      expect(html).not.toContain('data-testid="search-truncated-notice"')
      expect(html).toContain('ankole-pod-page-applet.html · 3.3 MB')
      const fillHtml = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <HtmlFilePreview
              cacheKey={cacheKey}
              url={url}
              name="ankole-pod-page-applet.html"
              size={3_500_000}
              canComment
              layout="fill"
              fileMeta={<span>ankole-pod-page-applet.html · 3.3 MB</span>}
            />
          </QueryClientProvider>
        </I18nextProvider>
      )

      expect(html).not.toContain('data-html-file-preview')
      expect(html).toContain('h-[min(68dvh,640px)]')
      expect(fillHtml).toContain('data-html-file-preview=""')
      expect(fillHtml).not.toContain('h-[min(68dvh,640px)]')
    } finally {
      client.clear()
    }
  })

  test('opens directly on the Source tab when a line comment anchor is targeted and shows oversized fallback above 16 MiB', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
    const cacheKey = ['pod-page-file', 'page-html-anchor'] as const
    const url = '/api/v2/pod/pages/page-html-anchor/files/content?path=index.html'
    const hugeUrl = '/api/v2/pod/pages/page-html-anchor/files/content?path=huge.html'

    client.setQueryData([...cacheKey, 'file-html-preview', url, 'full'], {
      previewHtml: '<!doctype html>\n<h1>Title</h1>\n<p>Body</p>',
      sourceText: '<!doctype html>\n<h1>Title</h1>\n<p>Body</p>',
      tooLarge: false,
      sourceTruncated: true,
      empty: false
    })
    client.setQueryData([...cacheKey, 'file-html-preview', hugeUrl, 'source-only'], {
      previewHtml: null,
      sourceText: '<!doctype html>\n<h1>Huge</h1>',
      tooLarge: true,
      sourceTruncated: true,
      empty: false
    })

    try {
      const anchoredHtml = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <HtmlFilePreview
              cacheKey={cacheKey}
              url={url}
              name="index.html"
              canComment
              initialAnchor={{ kind: 'lines', start_line: 2, end_line: 3 }}
            />
          </QueryClientProvider>
        </I18nextProvider>
      )

      expect(anchoredHtml).toContain('data-file-line="2"')
      expect(anchoredHtml).toContain('&lt;h1&gt;Title&lt;/h1&gt;')
      expect(anchoredHtml).toContain('data-testid="search-truncated-notice"')
      expect(anchoredHtml).toContain(`aria-label="${i18n.t('pod.chat_timeline.wrap_code')}"`)
      expect(anchoredHtml).toContain('aria-pressed="false"')

      const hugeHtml = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <HtmlFilePreview
              cacheKey={cacheKey}
              url={hugeUrl}
              name="huge.html"
              size={20 * 1024 * 1024}
              canComment={false}
            />
          </QueryClientProvider>
        </I18nextProvider>
      )
      expect(hugeHtml).not.toContain('<iframe')
      expect(hugeHtml).toContain('download="huge.html"')
    } finally {
      client.clear()
    }
  })

  test('renders TextFilePreview with horizontal-scroll default, line-wrap toggle, and line gutters', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
    const url = '/api/v2/pod/pages/page-code/files/content?path=server.ts'
    client.setQueryData([...contentKeys.page('page-code'), 'file-text-preview', url], {
      text: 'export const port = 4000\nconsole.log(port)',
      truncated: false
    })

    try {
      const html = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <TextFilePreview pageID="page-code" url={url} name="server.ts" canComment />
          </QueryClientProvider>
        </I18nextProvider>
      )
      expect(html).toContain('data-file-line="1"')
      expect(html).toContain('data-file-line="2"')
      expect(html).toContain('whitespace-pre')
      expect(html).toContain(`aria-label="${i18n.t('pod.chat_timeline.wrap_code')}"`)
      expect(html).toContain('aria-pressed="false"')
      expect(html).toContain(`</svg>${i18n.t('pod.chat.copy_code')}</button>`)
    } finally {
      client.clear()
    }
  })

  test('labels the plain-text copy button neutrally', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
    const url = '/api/v2/pod/pages/page-text/files/content?path=notes.txt'
    client.setQueryData([...contentKeys.page('page-text'), 'file-text-preview', url], {
      text: 'Meeting notes',
      truncated: false
    })

    try {
      const html = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <TextFilePreview pageID="page-text" url={url} name="notes.txt" canComment={false} />
          </QueryClientProvider>
        </I18nextProvider>
      )
      expect(html).toContain(`</svg>${i18n.t('common.copy')}</button>`)
      expect(html).not.toContain(i18n.t('pod.chat.copy_code'))
    } finally {
      client.clear()
    }
  })

  test('frames a located run once: side edges on every item, top on the first, bottom on the last', () => {
    const edges = (className: string) =>
      ['before:border-t', 'before:border-b'].filter(edge => className.split(' ').includes(edge))
    expect(edges(locatedRunClassName(true, false))).toEqual(['before:border-t'])
    expect(edges(locatedRunClassName(false, false))).toEqual([])
    expect(edges(locatedRunClassName(false, true))).toEqual(['before:border-b'])
    expect(edges(locatedRunClassName(true, true))).toEqual(['before:border-t', 'before:border-b'])
    expect(locatedRunClassName(false, false)).toContain('before:border-x')
  })
})

describe('FileSelectionToolbar', () => {
  test('localizes the CSV position label and labels the clear action as clearing the selection', async () => {
    await loadLocale('zh-Hans-CN')
    const zh = i18n.cloneInstance({ lng: 'zh-Hans-CN', initAsync: false })
    const html = renderToStaticMarkup(
      <I18nextProvider i18n={zh}>
        <FileSelectionToolbar
          selection={{ anchor: { kind: 'csv_rows', start_row: 3, end_row: 3, column: '联系人' }, quote: '' }}
          canComment
          onComment={() => undefined}
          onClear={() => undefined}
        />
      </I18nextProvider>
    )
    expect(html).toContain('第 3 行 · 联系人')
    expect(html).toContain(zh.t('pod.document.clear_selection'))
    expect(html).not.toContain(zh.t('pod.chat_timeline.clear_selection'))
  })
})
