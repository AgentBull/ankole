import {
  applyScrollFadeAttributes,
  computeScrollFadeEdges,
  ScrollFade,
  SplitLinkField,
  splitLinkURL
} from '@ankole/uikit'
import { beforeAll, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { extractDocumentPreviewSnippet, SharePagePreview } from './share-preview'

beforeAll(() => loadLocale('en-US'))

test('splitLinkURL separates host from decoded UTF-8 path, query, and hash', () => {
  expect(
    splitLinkURL('https://harbor.pod.example/pages/%E4%BA%A7%E5%93%81%E8%A7%84%E5%88%92-abc123?view=compact#sec-2')
  ).toEqual({
    host: 'harbor.pod.example',
    path: '/pages/产品规划-abc123?view=compact#sec-2'
  })

  expect(splitLinkURL('https://harbor.pod.example/')).toEqual({
    host: 'harbor.pod.example',
    path: ''
  })

  expect(splitLinkURL('harbor.pod.example:4000/pages/spec')).toEqual({
    host: 'harbor.pod.example:4000',
    path: '/pages/spec'
  })
})

test('extractDocumentPreviewSnippet strips code, diagrams, and formulas while joining readable lines', () => {
  expect(extractDocumentPreviewSnippet('<page/>')).toBeNull()
  expect(extractDocumentPreviewSnippet('')).toBeNull()

  const snippet = extractDocumentPreviewSnippet(
    '<page><h1>Architecture</h1><pre>const secret = 1</pre><mermaid>graph TD; A--&gt;B</mermaid><p>Edge fade &amp; outline polish.</p><math>E = mc^2</math></page>'
  )
  expect(snippet).toBe('Architecture · Edge fade & outline polish.')

  const withSelfClosingPreAndEntities = extractDocumentPreviewSnippet(
    '<page><pre /><p>Keep literal &amp;lt;script&amp;gt; text</p><pre>const hidden = true</pre><p>Trailing summary</p></page>'
  )
  expect(withSelfClosingPreAndEntities).toBe('Keep literal &lt;script&gt; text · Trailing summary')
})

test('computeScrollFadeEdges detects hidden content on horizontal (LTR & RTL) and vertical axes', () => {
  const noOverflow = { scrollWidth: 300, clientWidth: 300, scrollLeft: 0 } as HTMLElement
  expect(computeScrollFadeEdges(noOverflow, 'x')).toEqual({ moreStart: false, moreEnd: false })

  const xStart = { scrollWidth: 640, clientWidth: 300, scrollLeft: 0 } as HTMLElement
  expect(computeScrollFadeEdges(xStart, 'x')).toEqual({ moreStart: false, moreEnd: true })

  const xMiddleRtl = { scrollWidth: 640, clientWidth: 300, scrollLeft: -120 } as HTMLElement
  expect(computeScrollFadeEdges(xMiddleRtl, 'x')).toEqual({ moreStart: true, moreEnd: true })

  const yEnd = { scrollHeight: 900, clientHeight: 400, scrollTop: 500 } as HTMLElement
  expect(computeScrollFadeEdges(yEnd, 'y')).toEqual({ moreStart: true, moreEnd: false })

  const toggled = new Set<string>()
  const target = {
    toggleAttribute: (name: string, force?: boolean) => {
      if (force) toggled.add(name)
      else toggled.delete(name)
    }
  } as unknown as HTMLElement
  applyScrollFadeAttributes(target, { moreStart: true, moreEnd: false })
  expect([...toggled]).toEqual(['data-scroll-more-start'])
})

test('SplitLinkField places its polite status live region outside the button and renders host/path slots', async () => {
  const html = renderToStaticMarkup(
    <SplitLinkField
      url="https://harbor.pod.example/pages/design-notes-123"
      label="Copy link"
      copiedLabel="Page link copied"
    />
  )

  let hostText = ''
  let pathText = ''
  let statusInsideButton = false
  let statusSiblingCount = 0

  await new HTMLRewriter()
    .on('[data-slot="split-link-host"]', {
      text: chunk => {
        hostText += chunk.text
      }
    })
    .on('[data-slot="split-link-path"]', {
      text: chunk => {
        pathText += chunk.text
      }
    })
    .on('button [role="status"]', {
      element: () => {
        statusInsideButton = true
      }
    })
    .on('[data-slot="split-link-field"] > [role="status"]', {
      element: () => {
        statusSiblingCount++
      }
    })
    .transform(new Response(html))
    .text()

  expect(hostText).toBe('harbor.pod.example')
  expect(pathText).toBe('/pages/design-notes-123')
  expect(statusInsideButton).toBe(false)
  expect(statusSiblingCount).toBe(1)
})

test('ScrollFade and SharePagePreview render edge-fade bleed classes and realistic page previews', () => {
  const fadeHtml = renderToStaticMarkup(
    <ScrollFade axis="x">
      <span>Tab</span>
    </ScrollFade>
  )
  expect(fadeHtml).toContain('scroll-fade-x')
  expect(fadeHtml).toContain('scroll-bleed-y')

  const instance = i18n.cloneInstance({ lng: 'en-US', initAsync: false })
  const docPreview = renderToStaticMarkup(
    <I18nextProvider i18n={instance}>
      <SharePagePreview
        page={{
          id: '019a2b00-0000-7000-8000-000000000011',
          name: 'Quarterly Review',
          title: 'Stale Saved Title',
          type: 'doc',
          icon: '🧭'
        }}
        title="Live Unsaved Draft Title"
        bodyXML="<page><p> Crisp section outline and realistic share card. </p></page>"
        restricted={false}
        scopeLabel="Harbor Space"
      />
    </I18nextProvider>
  )
  expect(docPreview.replace(/[\u2068\u2069]/gu, '')).toContain('Preview of Live Unsaved Draft Title')
  expect(docPreview).toContain('Live Unsaved Draft Title')
  expect(docPreview).toContain('Crisp section outline and realistic share card.')
  expect(docPreview).toContain('Harbor Space')

  const filePreview = renderToStaticMarkup(
    <I18nextProvider i18n={instance}>
      <SharePagePreview
        page={{
          id: '019a2b00-0000-7000-8000-000000000012',
          name: 'budget-2026.xlsx',
          title: 'budget-2026.xlsx',
          type: 'file',
          icon: null
        }}
        restricted={true}
      />
    </I18nextProvider>
  )
  expect(filePreview).toContain('XLSX')
})
