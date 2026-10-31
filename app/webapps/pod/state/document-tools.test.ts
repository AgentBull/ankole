import { describe, expect, test } from 'bun:test'
import { parseMarkdown, parseXml, printXml } from '@ankole/block-editor/document'
import {
  documentAssets,
  documentEmbedIDs,
  documentFilename,
  documentMarkdown,
  documentPlainText,
  documentPrincipalUIDs,
  documentReferenceIDs,
  textStats
} from './document-tools'
import { DocumentToolsModel } from './document-tools-model'
import { PageDraftModel } from './page-draft'

describe('document export and statistics', () => {
  test('Markdown export preserves the title as text and round-trips the complete body', () => {
    const xml =
      '<page><p><strong>Report</strong> with a <a href="https://example.com">link</a>.</p><pre lang="ts">const n = 1</pre><blockquote><p>Keep this</p></blockquote></page>'
    const result = parseMarkdown(documentMarkdown(xml, '*Literal* [title]'))
    expect(result.children[0]).toEqual({
      type: 'element',
      name: 'h1',
      attrs: {},
      children: [{ type: 'text', value: '*Literal* [title]' }]
    })
    expect(printXml({ ...result, children: result.children.slice(1) })).toBe(printXml(parseXml(xml)))
  })

  test('Markdown export resolves page assets without modifying external links or content', () => {
    const source = 'ankole:asset/hash/photo.png'
    const exported = documentMarkdown(
      `<page><p><img src="${source}" alt="photo"/><a href="${source}">Download</a><a href="https://example.com">External</a></p></page>`,
      '',
      { resolveAsset: () => 'https://tenant.example.com/api/files?path=photo.png' }
    )
    expect(exported).not.toContain('ankole:asset/')
    expect(exported).toContain('https://tenant.example.com/api/files?path=photo.png')
    expect(exported).toContain('https://example.com')
  })

  test('portable copies preserve embedded page names, destinations, and surrounding text', () => {
    const xml =
      '<page><p>See <a href="ankole:page/report">summary</a>:</p><embed ref="report"/><p>Then continue.</p></page>'
    const projection = {
      resolveReference: () => ({ title: '*Quarterly* [report]', href: 'https://pod.example/pages/report' })
    }
    expect(documentReferenceIDs(xml)).toEqual(['report'])
    const markdown = documentMarkdown(xml, '', projection)
    expect(markdown).not.toContain('<embed')
    expect(markdown).not.toContain('ankole:page/')
    expect(documentPlainText(xml, projection)).toBe(
      'See summary (https://pod.example/pages/report):\n*Quarterly* [report] (https://pod.example/pages/report)\nThen continue.'
    )
    expect(documentPlainText(printXml(parseMarkdown(markdown)))).toBe(
      'See summary:\n*Quarterly* [report]\nThen continue.'
    )
  })

  test('inline page and principal mentions project into portable Markdown and plain text while redacting restricted targets', () => {
    const pageOk = '00112233-4455-6677-8899-aabbccddeeff'
    const pageRestricted = '11111111-2222-3333-4444-555555555555'
    const userOk = 'usr_alice001'
    const userRestricted = 'usr_secret09'
    const xml = `<page><p>Review <mention page="${pageOk}"/> and <mention page="${pageRestricted}"/> with <mention principal="${userOk}"/> and <mention principal="${userRestricted}"/>.</p></page>`

    expect(documentReferenceIDs(xml)).toEqual([pageOk, pageRestricted])
    expect(documentPrincipalUIDs(xml)).toEqual([userOk, userRestricted])

    const projection = {
      resolveReference: (id: string) =>
        id === pageOk
          ? { title: 'Q4 Design Spec', href: 'https://pod.example/pages/ABEiM0RVZneImaq7zN3u_w' }
          : { title: 'Restricted page', href: 'https://pod.example/pages/restricted', restricted: true },
      resolvePrincipal: (uid: string) =>
        uid === userOk ? { name: 'Alice Chen' } : { name: 'Restricted user', restricted: true }
    }

    const markdown = documentMarkdown(xml, '', projection)
    expect(markdown).toBe(
      'Review [Q4 Design Spec](https://pod.example/pages/ABEiM0RVZneImaq7zN3u_w) and Restricted page with @Alice Chen and @Restricted user.'
    )
    expect(markdown).not.toContain('<mention')
    expect(markdown).not.toContain('https://pod.example/pages/restricted')

    expect(documentPlainText(xml, projection)).toBe(
      'Review Q4 Design Spec and Restricted page with @Alice Chen and @Restricted user.'
    )
  })

  test('download collects only local assets and deduplicates image and attachment references', () => {
    const xml =
      '<page><p><img src="ankole:asset/hash/图.png"/><a href="ankole:asset/hash/图.png">Original</a><img src="https://example.com/remote.png"/></p><p><a href="ankole:asset/hash/notes.txt">Notes</a></p></page>'
    expect(documentAssets(xml)).toEqual(['ankole:asset/hash/图.png', 'ankole:asset/hash/notes.txt'])
  })

  test('plain-text copy reads body text without stripping literal syntax, code, or link labels', () => {
    expect(
      documentPlainText(
        '<page><h2>Heading</h2><p><strong>Bold</strong> and *literal* <a href="https://example.com">label</a><br/>Next</p><pre>let x = &quot;**code**&quot;</pre><p><img src="https://example.com/a.png" alt="Chart"/></p></page>'
      )
    ).toBe('Heading\nBold and *literal* label\nNext\nlet x = "**code**"\n(image: Chart)')
  })

  test('resource blocks export portable links and collect their uploaded files', () => {
    const xml =
      '<page><media src="ankole:asset/hash/photo.png" title="Photo"/><media src="ankole:asset/hash/movie.mp4" kind="video" title="Movie"/><bookmark src="https://example.com" title="Website" view="card"/><embed href="https://www.figma.com/design/test" title="Design"/></page>'
    expect(documentAssets(xml)).toEqual(['ankole:asset/hash/photo.png', 'ankole:asset/hash/movie.mp4'])
    expect(documentReferenceIDs(xml)).toEqual([])
    const markdown = documentMarkdown(xml, '', { resolveAsset: source => `./assets/${source.split('/').at(-1)}` })
    expect(markdown).toBe(
      '![Photo](./assets/photo.png)\n\n[Movie](./assets/movie.mp4)\n\n[Website](https://example.com)\n\n[Design](https://www.figma.com/design/test)'
    )
    expect(documentPlainText(xml)).toBe(
      'Photo (ankole:asset/hash/photo.png)\nMovie (ankole:asset/hash/movie.mp4)\nWebsite (https://example.com)\nDesign (https://www.figma.com/design/test)'
    )
    expect(documentPlainText(xml, { resolveAsset: source => `https://pod.example/${source.split('/').at(-1)}` })).toBe(
      'Photo (https://pod.example/photo.png)\nMovie (https://pod.example/movie.mp4)\nWebsite (https://example.com)\nDesign (https://www.figma.com/design/test)'
    )
  })

  test('editing stats count written text and skip resource titles and addresses', () => {
    const xml =
      '<page><p>Hello</p><media src="ankole:asset/hash/photo.png" title="photo.png"/><p>world<img src="ankole:asset/hash/inline.png" alt="chart"/></p></page>'
    expect(documentPlainText(xml, { omitResources: true })).toBe('Hello\nworld')
    expect(textStats(documentPlainText(xml, { omitResources: true })).words).toBe(2)
  })

  test('portable Markdown omits empty top-level paragraphs', () => {
    expect(documentMarkdown('<page><p>Hello</p><p /><p>World</p><p /></page>', 'Title')).toBe(
      '# Title\n\nHello\n\nWorld'
    )
  })

  test('plain-text copy separates nested list, column, and table text blocks', () => {
    const xml =
      '<page><ul><li><p>First</p><ul><li><p>Nested</p></li></ul></li></ul><columns><column><p>Left</p></column><column><p>Right</p></column></columns><table><tr><th><p>Name</p></th><th><p>Count</p></th></tr><tr><td><p>Item</p></td><td><p>2</p></td></tr></table></page>'
    expect(documentPlainText(xml)).toBe('First\nNested\nLeft\nRight\nName\tCount\nItem\t2')
  })

  test('portable Markdown flattens layout columns and styles into normal readable blocks', () => {
    const xml =
      '<page><columns><column width="30"><p align="center"><span style="color: red">Left</span></p></column><column width="70"><callout tone="warning"><p>Right</p></callout></column></columns></page>'
    expect(documentMarkdown(xml, '')).toBe('Left\n\n> Right')
  })

  test('empty documents have no title, words, characters, or reading time', () => {
    expect(documentMarkdown('<page/>', '')).toBe('')
    expect(documentPlainText('<page/>')).toBe('')
    expect(textStats('')).toEqual({ words: 0, characters: 0, paragraphs: 0, readingTime: 0 })
  })

  test('editing stats count Unicode words, paragraphs, and approximate reading time', () => {
    const text = 'Hello-world\n\nSecond paragraph here'
    expect(textStats(text)).toEqual({ words: 5, characters: text.length, paragraphs: 2, readingTime: 1 })
    expect(textStats('word '.repeat(400)).readingTime).toBe(2)
    expect(textStats('word '.repeat(401)).readingTime).toBe(3)
    expect(textStats('中文 😀').characters).toBe(5)
    for (const text of ['你好世界欢迎阅读这份文档', 'これは日本語の文章です', '한국어 문장을 작성합니다 ']) {
      expect(textStats(text).words).toBeGreaterThan(1)
      expect(textStats(text.repeat(400)).readingTime).toBeGreaterThan(1)
    }
    expect(textStats('😀 — !!').words).toBe(0)
  })

  test('export filenames cannot create paths or dotfiles and have a usable empty-title fallback', () => {
    expect(documentFilename(' Project: A/B ')).toBe('Project--A-B.md')
    expect(documentFilename('  /  ')).toBe('document.md')
    expect(documentFilename('.env')).toBe('env.md')
    expect(documentFilename('...')).toBe('document.md')
    expect(documentFilename('...', 'document-draft')).toBe('document-draft.md')
  })

  test('documentEmbedIDs collects only block embeds and ignores inline page links or mentions', () => {
    const xml =
      '<page><p>Read <mention page="mention-file"/> and <a href="ankole:page/link-file">spec</a>.</p><embed ref="embedded-file"/><embed ref="embedded-file"/></page>'
    expect(documentReferenceIDs(xml)).toEqual(['mention-file', 'link-file', 'embedded-file'])
    expect(documentEmbedIDs(xml)).toEqual(['embedded-file'])
  })

  test('DocumentToolsModel skips parsing while hidden, debounces typing updates, and clears timers on dispose', async () => {
    const draft = new PageDraftModel()
    draft.source.value = 'page-1'
    draft.xml.value = '<page><p>One two</p></page>'
    const tools = new DocumentToolsModel(draft)
    try {
      expect(tools.stats.value.words).toBe(0)

      tools.setShowStats(true)
      expect(tools.stats.value.words).toBe(2)

      draft.xml.value = '<page><p>One two three four</p></page>'
      // Typing in the same document waits for the debounce window before reparsing XML.
      expect(tools.stats.value.words).toBe(2)
      await new Promise(resolve => setTimeout(resolve, 180))
      expect(tools.stats.value.words).toBe(4)

      draft.xml.value = '<page><p>One two three four five six</p></page>'
      expect(tools.stats.value.words).toBe(4)
      tools.dispose()
      await new Promise(resolve => setTimeout(resolve, 180))
      expect(tools.stats.value.words).toBe(4)
    } finally {
      tools.dispose()
      tools[Symbol.dispose]()
      draft[Symbol.dispose]()
    }
  })
})
