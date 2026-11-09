import { expect, test } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { applyBlockType, blockTypeAt } from '../src/editor/block-actions'
import { filterBlockOptions } from '../src/editor/block-catalog'
import { foldedHeadings, headingSections, toggleHeading } from '../src/editor/headings'
import { changeTable } from '../src/editor/tables'
import { undo } from '../src/editor/commands'
import { insertResource, resourceChanges } from '../src/blocks/resources'
import { EmbedHeight, EmbedHref, EmbedTitle, embedChanges } from '../src/blocks/embed'
import {
  iframeURL,
  mediaKind,
  normalizeWebURL,
  replaceResourceSource,
  resourceContent,
  resourceText,
  videoEmbedURL,
  webURL
} from '../src/document/resources'
import { element, type Element } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { closeFileUpload, fileUploadField } from '../src/editor/file-upload'
import { knowledgeExtension } from '../src/editor/knowledge'
import {
  availableLinkViews,
  convertInlineLinkView,
  convertPageEmbedToMention,
  convertPageMentionToEmbed,
  convertResourceBlockView,
  fallbackLinkTitle,
  fetchLinkMetadata,
  inlineLinkView,
  unfurlEmbed
} from '../src/editor/link-views'
import { linkAt, linkAtPos, singleLinkInRange, updateLinkAt } from '../src/editor/links'
import { EditorContext } from '../src/react/context'
import { ExternalEmbedBlock, MediaResourceBlock } from '../src/react/ResourceBlocks'
import { expectReopens, exportMarkdown, open, openWithHost, readTree, select, typeText } from './helpers'

test('all six headings can be inserted, identified, reopened and undone', () => {
  for (let level = 1; level <= 6; level++) {
    const editor = open('Section')
    select(editor, 1)
    expect(applyBlockType(editor, `h${level}`)).toBe(true)
    expect(blockTypeAt(editor.state, 0)).toBe(`h${level}`)
    expect(exportMarkdown(editor)).toBe(`${'#'.repeat(level)} Section`)
    expectReopens(editor)
    undo(editor)
    expect(exportMarkdown(editor)).toBe('Section')
  }
})

test('folding follows sibling heading levels, maps edits and never changes saved content', () => {
  const editor = open('# A\n\none\n\n## B\n\ntwo\n\n# C\n\nthree')
  const xml = printXml(readTree(editor))
  const sections = headingSections(editor.state.doc)
  expect(sections).toHaveLength(3)
  expect(sections[0]!.to).toBe(sections[2]!.pos)
  expect(sections[1]!.to).toBe(sections[2]!.pos)
  editor.dispatch({ effects: toggleHeading.of(0) })
  expect(editor.state.field(foldedHeadings).has(0)).toBe(true)
  expect(printXml(readTree(editor))).toBe(xml)
  select(editor, sections[1]!.pos + 1)
  expect(editor.state.field(foldedHeadings).size).toBe(0)
  editor.dispatch({ effects: toggleHeading.of(sections[2]!.pos) })
  select(editor, 1)
  typeText(editor, 'new ')
  expect(editor.state.field(foldedHeadings).has(sections[2]!.pos + 4)).toBe(true)
})

test('folding reused containers keeps each occurrence within its own boundaries', () => {
  const editor = open(parseXml('<page><blockquote><h1>A</h1><p>inside</p></blockquote><p>unrelated</p></page>'))
  const quote = editor.state.doc.content[0]!
  const end = editor.state.doc.length
  editor.dispatch({ changes: { from: end, to: end, insert: [quote] } })
  expect(editor.state.doc.content.at(-1)).toBe(quote)
  expect(headingSections(editor.state.doc)).toEqual([
    { pos: 1, from: 4, to: 12, text: 'A' },
    { pos: 25, from: 28, to: 36, text: 'A' }
  ])
  const xml = printXml(readTree(editor))
  editor.dispatch({ effects: toggleHeading.of(1) })
  select(editor, quote.length + 1)
  expect(editor.state.field(foldedHeadings).has(1)).toBe(true)
  select(editor, 5)
  expect(editor.state.field(foldedHeadings).has(1)).toBe(false)
  expect(printXml(readTree(editor))).toBe(xml)
})

test('every block searches translated titles and multiple Chinese and English aliases', () => {
  const editor = open('')
  for (const query of ['图片', '媒体', 'media', 'picture', 'img', 'VIDEO']) {
    expect(filterBlockOptions(editor.state, query).map(option => option.type)).toContain('media')
  }
  for (const [query, kind] of [
    ['书签', 'bookmark'],
    ['iframe', 'embed'],
    ['高亮', 'callout'],
    ['表格', 'table'],
    ['h6', 'h6'],
    ['六级标题', 'h6'],
    ['待办', 'check']
  ]) {
    expect(filterBlockOptions(editor.state, query!).map(option => option.type)).toContain(kind!)
  }
  expect(filterBlockOptions(editor.state, '  HEADER   H5 ').map(option => option.type)).toEqual(['h5'])
})

test('the file entry needs a host that accepts files and opens the upload panel without editing the page', () => {
  expect(filterBlockOptions(open('').state, 'upload').map(option => option.type)).not.toContain('file')
  expect(applyBlockType(open('Text'), 'file')).toBe(false)

  const editor = openWithHost('Notes /附件', { acceptFiles: async () => {} })
  for (const query of ['附件', 'upload', 'file', '文件']) {
    expect(filterBlockOptions(editor.state, query).map(option => option.type)).toContain('file')
  }
  // The slash query `/附件` is three characters before the caret.
  const to = editor.state.selection.head
  expect(applyBlockType(editor, 'file', { from: to - 3, to })).toBe(true)
  expect(exportMarkdown(editor)).toBe('Notes&#x20;')
  expect(editor.state.field(fileUploadField)).toBe(editor.state.selection.head)
  editor.dispatch({ effects: closeFileUpload.of(null) })
  expect(editor.state.field(fileUploadField)).toBeNull()
})

test('uploaded media, webpage metadata and external embeds survive both codecs', () => {
  const editor = open(
    parseXml(
      '<page><media kind="video" src="ankole:asset/clip.mp4" mime="video/mp4" title="Clip" /><embed href="https://example.com" title="Example" description="Description" image="https://example.com/image.png" view="card" /><embed href="https://www.figma.com/design/example" title="Design" /><callout tone="success" icon="✅"><p>Ready</p></callout></page>'
    )
  )
  expectReopens(editor)
  const before = readTree(editor)
  select(editor)
  expect(insertResource(editor, 'media', { src: 'https://example.com/photo.png', kind: 'image' })).toBe(true)
  expectReopens(editor)
  undo(editor)
  expect(readTree(editor)).toEqual(before)
})

test('embed display transforms canonical provider links and rejects executable URLs', () => {
  const figma = 'https://www.figma.com/design/abc/Design?node-id=1-2'
  expect(iframeURL(figma)).toBe(`https://www.figma.com/embed?embed_host=ankole&url=${encodeURIComponent(figma)}`)
  expect(videoEmbedURL('https://youtu.be/dQw4w9WgXcQ?t=30s')).toBe(
    'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?start=30'
  )
  expect(videoEmbedURL('https://vimeo.com/123456')).toBe('https://player.vimeo.com/video/123456')
  expect(mediaKind({ src: 'https://example.com/clip.webm' })).toBe('video')
  expect(mediaKind({ src: 'ankole:asset/no-extension', mime: 'video/mp4' })).toBe('video')
  for (const url of [
    'javascript:alert(1)',
    'data:text/html,hello',
    '//example.com',
    'https://user:secret@example.com'
  ]) {
    expect(webURL(url)).toBeNull()
  }
  expect(videoEmbedURL('https://youtube.com.attacker.test/watch?v=dQw4w9WgXcQ')).toBeNull()
})

test('a document containing only one resource saves attribute edits and supports undo', () => {
  const editor = open('<embed href="" />')
  editor.dispatch({
    changes: [
      { from: 0, add: EmbedHref.of('https://example.com/') },
      { from: 0, add: EmbedTitle.of('External') }
    ]
  })
  expect(exportMarkdown(editor)).toBe('<embed href="https://example.com/" title="External" />')
  expectReopens(editor)
  undo(editor)
  expect(exportMarkdown(editor)).toBe('<embed href="" />')

  const media = open('<media src="https://example.com/photo.png" custom="kept" />')
  media.dispatch({
    changes: resourceChanges(media.state.doc.content[0]!, 0, { src: 'https://example.com/photo.png', view: 'card' })
  })
  expect(exportMarkdown(media)).toBe('<media custom="kept" src="https://example.com/photo.png" view="card" />')
  expectReopens(media)
  undo(media)
  expect(exportMarkdown(media)).toBe('<media custom="kept" src="https://example.com/photo.png" />')
})

test('table menu creates editable cells and row, column, header and alignment edits are undoable', () => {
  const editor = open('')
  expect(applyBlockType(editor, 'table')).toBe(true)
  typeText(editor, 'Name')
  expect(exportMarkdown(editor)).toContain('| Name |')
  const before = readTree(editor)
  for (const action of ['row_after', 'column_after', 'header', 'align_right', 'delete_column', 'delete_row'] as const) {
    expect(changeTable(editor, action)).toBe(true)
    expectReopens(editor)
  }
  for (let i = 0; i < 6; i++) undo(editor)
  expect(readTree(editor)).toEqual(before)
})

test('resource and embed patches preserve unrelated remote metadata and remove only explicit fields', () => {
  const editor = open(
    '<embed href="https://example.com" title="Old" description="Remote edit" view="card" height="600" custom="kept" />'
  )
  const before = readTree(editor)
  editor.dispatch({ changes: embedChanges(editor.state.doc.content[0]!, 0, { title: 'Local edit' }) })
  expect(readTree(editor).children[0]).toEqual({
    type: 'element',
    name: 'embed',
    children: [],
    attrs: {
      href: 'https://example.com',
      title: 'Local edit',
      description: 'Remote edit',
      view: 'card',
      height: '600',
      custom: 'kept'
    }
  })
  undo(editor)
  expect(readTree(editor)).toEqual(before)
  editor.dispatch({ changes: embedChanges(editor.state.doc.content[0]!, 0, { description: undefined }) })
  expect(exportMarkdown(editor)).not.toContain('description=')
  expect(exportMarkdown(editor)).toContain('view="card"')
  expectReopens(editor)
})

test('changing a media source discards the previous upload facts and infers its new content', () => {
  const editor = open(
    '<media src="ankole:asset/photo" mime="image/png" size="100" kind="image" title="Keep title" view="card" />'
  )
  editor.dispatch({
    changes: resourceChanges(
      editor.state.doc.content[0]!,
      0,
      replaceResourceSource({ src: 'https://example.com/movie.mp4' })
    )
  })
  const node = readTree(editor).children[0] as Element
  expect(node.attrs).toEqual({ src: 'https://example.com/movie.mp4', title: 'Keep title', view: 'card' })
  expect(mediaKind(node.attrs)).toBe('video')
  expect(resourceContent(node)?.image).toBe(false)
  expectReopens(editor)
  undo(editor)
  expect((readTree(editor).children[0] as Element).attrs.mime).toBe('image/png')
})

test('resource projections use the same explicit kind, MIME and URL precedence as previews', () => {
  for (const [attrs, image] of [
    [{ src: 'https://example.com/photo.png' }, true],
    [{ src: 'ankole:asset/no-extension', mime: 'video/mp4' }, false],
    [{ src: 'https://example.com/movie.mp4', mime: 'image/png', kind: 'video' }, false],
    [{ src: 'https://example.com/movie.mp4', kind: 'image' }, true]
  ] as const) {
    expect(resourceContent(element('media', attrs))?.image).toBe(image)
  }
  expect(
    resourceText(element('embed', { href: 'https://example.com/report.pdf', title: 'Report', view: 'card' }))
  ).toBe('Report (https://example.com/report.pdf)')
  expect(resourceText(element('embed', { href: 'https://example.com' }))).toBe('https://example.com')
  expect(resourceContent(element('embed', { ref: 'page-id' }))).toBeNull()
})

test('ResourceBlocks handles malformed URLs, relative asset paths, and strips allow-same-origin on same-origin iframes', () => {
  const editor = open('')
  const handle = {
    editor,
    drawn: () => editor.state,
    subscribe: () => () => {}
  }
  const container = { isConnected: false } as unknown as globalThis.Element
  const previousWindow = (globalThis as { window?: unknown }).window
  ;(globalThis as { window?: unknown }).window = {
    location: new URL('https://pod.ankole.test/spaces/general')
  }
  try {
    // Invalid URL from resolveAsset in card view renders fallback hostname text without throwing.
    const invalidCardHtml = renderToStaticMarkup(
      createElement(
        EditorContext.Provider,
        { value: handle },
        createElement(MediaResourceBlock, {
          attrs: { src: 'ankole:asset/broken', title: 'Broken', view: 'card' },
          container,
          host: { resolveAsset: () => 'http://[::1:bad-url' }
        })
      )
    )
    expect(invalidCardHtml).toContain('<small>http://[::1:bad-url</small>')

    // Relative asset URL where iframeURL returns null skips rendering an empty/null iframe.
    const relativeEmbedHtml = renderToStaticMarkup(
      createElement(
        EditorContext.Provider,
        { value: handle },
        createElement(ExternalEmbedBlock, {
          attrs: { href: 'ankole:asset/applet', title: 'Relative Applet' },
          container,
          host: { resolveAsset: () => '/pod/applet-frame/123' }
        })
      )
    )
    expect(relativeEmbedHtml).not.toContain('<iframe')

    // Same-origin absolute URL omits allow-same-origin from sandbox.
    const sameOriginHtml = renderToStaticMarkup(
      createElement(
        EditorContext.Provider,
        { value: handle },
        createElement(ExternalEmbedBlock, {
          attrs: { href: 'https://pod.ankole.test/pod/applet-frame/123', title: 'Applet' },
          container
        })
      )
    )
    expect(sameOriginHtml).toContain('sandbox="allow-scripts allow-popups allow-forms"')
    expect(sameOriginHtml).not.toContain('allow-same-origin')

    // Cross-origin URL keeps allow-same-origin on sandbox for third-party embeds.
    const crossOriginHtml = renderToStaticMarkup(
      createElement(
        EditorContext.Provider,
        { value: handle },
        createElement(ExternalEmbedBlock, {
          attrs: { href: 'https://external.example/embed/1', title: 'External' },
          container
        })
      )
    )
    expect(crossOriginHtml).toContain('sandbox="allow-scripts allow-same-origin allow-popups allow-forms"')
  } finally {
    if (previousWindow === undefined) delete (globalThis as { window?: unknown }).window
    else (globalThis as { window?: unknown }).window = previousWindow
  }
})

test('webpage links convert across link, title, card, and embed preview views with single-step undo', async () => {
  const url = 'https://arxiv.org/abs/2510.04374'
  const editor = openWithHost(url, {
    resolveLinkMetadata: async () => ({
      title: 'GDPval: Evaluating AI Model Performance',
      description: 'Benchmarking real-world economically valuable tasks.',
      image: 'https://arxiv.org/static/browse/0.3.4/images/arxiv-logo-fb.png',
      icon: 'https://arxiv.org/favicon.ico'
    })
  })

  select(editor, 5)
  const initialLink = linkAt(editor.state)!
  expect(inlineLinkView(editor.state, initialLink)).toBe('link')
  expect(availableLinkViews(editor.state)).toEqual(['link', 'title', 'card', 'preview'])

  // 1. Link view -> Title view (fetches metadata title)
  expect(await convertInlineLinkView(editor, initialLink, 'title')).toBe(true)
  expect(exportMarkdown(editor)).toBe(`[GDPval: Evaluating AI Model Performance](${url})`)
  const titledLink = linkAt(editor.state)!
  expect(inlineLinkView(editor.state, titledLink)).toBe('title')

  // 2. Title view -> Card view (`<embed href="..." view="card" />` with unfurled description + image)
  expect(await convertInlineLinkView(editor, titledLink, 'card')).toBe(true)
  expect(blockTypeAt(editor.state, 0)).toBe('bookmark')
  await Promise.resolve()
  await Promise.resolve()
  expect(exportMarkdown(editor)).toBe(
    `<embed description="Benchmarking real-world economically valuable tasks." href="${url}" image="https://arxiv.org/static/browse/0.3.4/images/arxiv-logo-fb.png" title="GDPval: Evaluating AI Model Performance" view="card" />`
  )

  // Single undo returns directly to the inline titled link despite async metadata unfurling!
  undo(editor)
  expect(exportMarkdown(editor)).toBe(`[GDPval: Evaluating AI Model Performance](${url})`)

  // Re-convert to Card -> Preview -> Card on the SAME `<embed>` node, preserving description, image, and height!
  const relink = linkAt(editor.state)!
  expect(await convertInlineLinkView(editor, relink, 'card')).toBe(true)
  editor.dispatch({ changes: [{ from: 0, add: EmbedHeight.of('640') }] })
  expect(await convertResourceBlockView(editor, 0, 'preview')).toBe(true)
  expect(blockTypeAt(editor.state, 0)).toBe('embed')
  expect(exportMarkdown(editor)).toBe(
    `<embed description="Benchmarking real-world economically valuable tasks." height="640" href="${url}" image="https://arxiv.org/static/browse/0.3.4/images/arxiv-logo-fb.png" title="GDPval: Evaluating AI Model Performance" />`
  )
  expect(await convertResourceBlockView(editor, 0, 'card')).toBe(true)
  expect(blockTypeAt(editor.state, 0)).toBe('bookmark')
  expect(exportMarkdown(editor)).toBe(
    `<embed description="Benchmarking real-world economically valuable tasks." height="640" href="${url}" image="https://arxiv.org/static/browse/0.3.4/images/arxiv-logo-fb.png" title="GDPval: Evaluating AI Model Performance" view="card" />`
  )

  expect(await convertResourceBlockView(editor, 0, 'link')).toBe(true)
  expect(printXml(readTree(editor))).toBe(`<page><p><a href="${url}">${url}</a></p></page>`)
})

test('converting a mid-paragraph inline link to card or preview splits surrounding text cleanly and undoes in one step', async () => {
  const editor = open('Before [Guide](https://example.com/docs/intro) after')
  const link = linkAtPos(editor.state, 9)!
  expect(inlineLinkView(editor.state, link)).toBe('title')
  expect(await convertInlineLinkView(editor, link, 'preview')).toBe(true)
  expect(exportMarkdown(editor)).toBe(
    'Before\n\n<embed href="https://example.com/docs/intro" title="Guide" />\n\nafter'
  )
  undo(editor)
  expect(exportMarkdown(editor)).toBe('Before [Guide](https://example.com/docs/intro) after')

  // Knowledge mode offers only inline link and title views, rejecting block conversions.
  const knowledge = open('https://example.com/docs/intro', [knowledgeExtension])
  select(knowledge, 4)
  const kLink = linkAt(knowledge.state)!
  expect(availableLinkViews(knowledge.state)).toEqual(['link', 'title'])
  expect(await convertInlineLinkView(knowledge, kLink, 'card')).toBe(false)
  expect(await convertInlineLinkView(knowledge, kLink, 'preview')).toBe(false)
  expect(await convertInlineLinkView(knowledge, kLink, 'title')).toBe(true)
  expect(fallbackLinkTitle('https://www.example.com/docs/intro/')).toBe('example.com/docs/intro')
  expect(exportMarkdown(knowledge)).toBe('[example.com/docs/intro](https://example.com/docs/intro)')
})

test('normalizeWebURL accepts bare domains while rejecting executable or malformed URLs', () => {
  expect(normalizeWebURL('figma.com/design/abc/Spec')).toBe('https://figma.com/design/abc/Spec')
  expect(normalizeWebURL('  arxiv.org/abs/2510.04374  ')).toBe('https://arxiv.org/abs/2510.04374')
  expect(normalizeWebURL('http://localhost:8080/frame')).toBe('http://localhost:8080/frame')
  for (const invalid of [
    '',
    '   ',
    'javascript:alert(1)',
    'data:text/html,hi',
    'just-a-word',
    'https://u:p@example.com'
  ]) {
    expect(normalizeWebURL(invalid)).toBeNull()
  }
})

test('singleLinkInRange detects a single link covering a non-empty selection and rejects partial or multi-link selections', () => {
  const editor = open('Intro [First](https://example.com/1) and [Second](https://example.com/2) end')
  // Full link "First" spans offsets 7..12 inside paragraph at pos 0 (text starts at doc offset 1)
  const first = linkAtPos(editor.state, 8)!
  select(editor, first.to, first.from)
  expect(singleLinkInRange(editor.state, editor.state.selection)).toEqual(first)

  // Subset inside the same link also resolves to that link
  select(editor, first.to - 1, first.from + 1)
  expect(singleLinkInRange(editor.state, editor.state.selection)).toEqual(first)

  // Extending selection into plain text outside the link returns null
  select(editor, first.to, 1)
  expect(singleLinkInRange(editor.state, editor.state.selection)).toBeNull()

  // Spanning across two links returns null
  const second = linkAtPos(editor.state, first.to + 6)!
  select(editor, second.to, first.from)
  expect(singleLinkInRange(editor.state, editor.state.selection)).toBeNull()
})

test('unfurlEmbed populates missing external embed titles outside undo history, and embed height round-trips cleanly', async () => {
  const url = 'https://arxiv.org/abs/2510.04374'
  const editor = openWithHost(url, {
    resolveLinkMetadata: async () => ({
      title: 'GDPval: Evaluating AI Model Performance'
    })
  })

  select(editor, 4)
  const link = linkAt(editor.state)!
  expect(await convertInlineLinkView(editor, link, 'preview')).toBe(true)
  await Bun.sleep(0)
  expect(exportMarkdown(editor)).toBe(`<embed href="${url}" title="GDPval: Evaluating AI Model Performance" />`)

  // Single undo steps directly back to the bare URL link because unfurlEmbed attached outside history
  undo(editor)
  expect(exportMarkdown(editor)).toBe(url)

  // Persisted height mark round-trips through XML and Markdown and can be updated and undone
  const sized = open('<embed href="https://example.com/frame" title="Board" height="620" />')
  expect(exportMarkdown(sized)).toBe('<embed height="620" href="https://example.com/frame" title="Board" />')
  expectReopens(sized)
  sized.dispatch({
    changes: [
      { from: 0, remove: EmbedHeight.of('620') },
      { from: 0, add: EmbedHeight.of('780') }
    ]
  })
  expect(exportMarkdown(sized)).toBe('<embed height="780" href="https://example.com/frame" title="Board" />')
  undo(sized)
  expect(exportMarkdown(sized)).toBe('<embed height="620" href="https://example.com/frame" title="Board" />')

  // unfurlEmbed leaves manual titles untouched
  await unfurlEmbed(sized, 'https://example.com/frame', 0)
  expect(exportMarkdown(sized)).toBe('<embed height="620" href="https://example.com/frame" title="Board" />')
})

test('internal page mentions and page embeds toggle two-way with single-step undo, and page_embed appears in block catalog when supported', () => {
  const pageId = '019a2b00-0000-7000-8000-000000000102'
  let insertedCount = 0
  const editor = openWithHost(parseXml(`<page><p>See <mention page="${pageId}" /> below</p></page>`), {
    canEmbedPage: id => id === pageId,
    insertPageEmbed: () => {
      insertedCount++
    }
  })

  expect(filterBlockOptions(open('').state, '多维表').map(o => o.type)).not.toContain('page_embed')
  for (const query of ['多维表', '应用', 'base', 'applet']) {
    expect(filterBlockOptions(editor.state, query).map(o => o.type)).toContain('page_embed')
  }

  // Mention at offset 5..6 (inside `<p>See [mention] below</p>`) converts to `<embed ref="..." />`
  expect(convertPageMentionToEmbed(editor, { from: 5, to: 6 }, pageId)).toBe(true)
  expect(printXml(readTree(editor))).toBe(`<page><p>See</p><embed ref="${pageId}" /><p>below</p></page>`)

  // Single undo restores the inline mention inside the original paragraph
  undo(editor)
  expect(printXml(readTree(editor))).toBe(`<page><p>See <mention page="${pageId}" /> below</p></page>`)

  // Convert again and collapse `<embed ref>` (at block offset 5: `<p>See</p>` has length 5) back to `<mention page>`
  expect(convertPageMentionToEmbed(editor, { from: 5, to: 6 }, pageId)).toBe(true)
  expect(convertPageEmbedToMention(editor, 5, pageId)).toBe(true)
  expect(printXml(readTree(editor))).toBe(`<page><p>See</p><p><mention page="${pageId}" /></p><p>below</p></page>`)
  undo(editor)
  expect(printXml(readTree(editor))).toBe(`<page><p>See</p><embed ref="${pageId}" /><p>below</p></page>`)

  // Selecting `page_embed` from a `/base` slash query cleans the slash text and invokes host.insertPageEmbed()
  const slashEditor = openWithHost('Plan /base', {
    insertPageEmbed: () => {
      insertedCount++
    }
  })
  const to = slashEditor.state.selection.head
  expect(applyBlockType(slashEditor, 'page_embed', { from: to - 5, to })).toBe(true)
  expect(exportMarkdown(slashEditor)).toBe('Plan&#x20;')
  expect(insertedCount).toBe(1)
})

test('media link view renders human-readable asset title instead of raw ankole:asset URI', () => {
  const editor = open('')
  const handle = {
    editor,
    drawn: () => editor.state,
    subscribe: () => () => {}
  }
  const container = { isConnected: false } as unknown as globalThis.Element
  const html = renderToStaticMarkup(
    createElement(
      EditorContext.Provider,
      { value: handle },
      createElement(MediaResourceBlock, {
        attrs: { src: 'ankole:asset/019a-video', title: 'Quarterly Demo.mp4', view: 'link' },
        container,
        host: { resolveAsset: () => 'https://cdn.ankole.test/assets/019a-video' }
      })
    )
  )
  expect(html).toContain('Quarterly Demo.mp4')
  expect(html).not.toContain('>ankole:asset/019a-video<')
})

test('same-view inline switch skips redundant undo steps, and late async unfurls preserve user edits and cursor focus', async () => {
  // 1. Clicking the already-active inline view does not push a no-op undo step.
  const inlineEditor = open('Intro\n\nhttps://example.com/spec')
  select(inlineEditor, 6)
  typeText(inlineEditor, '!')
  const activeLink = linkAtPos(inlineEditor.state, 10)!
  expect(inlineLinkView(inlineEditor.state, activeLink)).toBe('link')
  expect(await convertInlineLinkView(inlineEditor, activeLink, 'link')).toBe(true)
  undo(inlineEditor)
  expect(exportMarkdown(inlineEditor)).toBe('Intro\n\nhttps://example.com/spec')

  // 2. Moving cursor to another paragraph while block -> title unfurl is in flight does not yank selection back.
  let finishFirst!: (meta: { title: string }) => void
  const cursorEditor = openWithHost('<embed href="https://example.com/slow" view="card" />\n\nSecond paragraph', {
    resolveLinkMetadata: () =>
      new Promise(resolve => {
        finishFirst = resolve
      })
  })
  const pendingFirst = convertResourceBlockView(cursorEditor, 0, 'title')
  await Promise.resolve()
  const secondParaEnd = cursorEditor.state.doc.length - 1
  select(cursorEditor, secondParaEnd)
  finishFirst({ title: 'Slow Title' })
  expect(await pendingFirst).toBe(true)
  expect(exportMarkdown(cursorEditor)).toBe('[Slow Title](https://example.com/slow)\n\nSecond paragraph')
  expect(cursorEditor.state.selection.head).toBe(cursorEditor.state.doc.length - 1)

  // 3. Manually editing the link text while block -> title unfurl is in flight keeps the manual text intact.
  let finishSecond!: (meta: { title: string }) => void
  const editedEditor = openWithHost('<embed href="https://example.com/custom" view="card" />', {
    resolveLinkMetadata: () =>
      new Promise(resolve => {
        finishSecond = resolve
      })
  })
  const pendingSecond = convertResourceBlockView(editedEditor, 0, 'title')
  await Promise.resolve()
  const insertedLink = linkAtPos(editedEditor.state, 2)!
  expect(updateLinkAt(editedEditor, insertedLink, { href: 'https://example.com/custom', text: 'Manual Label' })).toBe(
    true
  )
  finishSecond({ title: 'Stale Async Title' })
  expect(await pendingSecond).toBe(true)
  expect(exportMarkdown(editedEditor)).toBe('[Manual Label](https://example.com/custom)')
})

test('in-flight inline and embed metadata requests track their target via transactions instead of guessing by URL', async () => {
  const url = 'https://example.com/shared'

  // 1. Deleting the original bare link while metadata is pending never overwrites another link with the same URL.
  let finishDuplicate!: (meta: { title: string }) => void
  const dupEditor = openWithHost(`${url}\n\n[Handwritten Title](${url})`, {
    resolveLinkMetadata: () =>
      new Promise(resolve => {
        finishDuplicate = resolve
      })
  })
  const firstLink = linkAtPos(dupEditor.state, 3)!
  const pendingDup = convertInlineLinkView(dupEditor, firstLink, 'title')
  await Promise.resolve()
  // Delete the first paragraph (`<p>https://example.com/shared</p>` spans 0 .. firstLink.to + 1)
  dupEditor.dispatch({ changes: { from: 0, to: firstLink.to + 1 } })
  finishDuplicate({ title: 'Fetched Remote Title' })
  expect(await pendingDup).toBe(false)
  expect(exportMarkdown(dupEditor)).toBe(`[Handwritten Title](${url})`)

  // 2. Editing the target link's title while metadata is pending cancels the async overwrite and keeps cursor in place.
  let finishEdited!: (meta: { title: string }) => void
  const manualEditor = openWithHost(`${url}\n\nNotes`, {
    resolveLinkMetadata: () =>
      new Promise(resolve => {
        finishEdited = resolve
      })
  })
  const targetLink = linkAtPos(manualEditor.state, 3)!
  const pendingEdited = convertInlineLinkView(manualEditor, targetLink, 'title')
  await Promise.resolve()
  expect(updateLinkAt(manualEditor, targetLink, { href: url, text: 'My Custom Title' })).toBe(true)
  const notesEnd = manualEditor.state.doc.length - 1
  select(manualEditor, notesEnd)
  finishEdited({ title: 'Fetched Remote Title' })
  expect(await pendingEdited).toBe(false)
  expect(exportMarkdown(manualEditor)).toBe(`[My Custom Title](${url})\n\nNotes`)
  expect(manualEditor.state.selection.head).toBe(notesEnd)

  // 3. Typing earlier in the doc and moving cursor away maps the target link accurately without yanking selection.
  let finishShifted!: (meta: { title: string }) => void
  const shiftedEditor = openWithHost(`Lead\n\n${url}\n\nTail`, {
    resolveLinkMetadata: () =>
      new Promise(resolve => {
        finishShifted = resolve
      })
  })
  const midLink = linkAtPos(shiftedEditor.state, 8)!
  const pendingShifted = convertInlineLinkView(shiftedEditor, midLink, 'title')
  await Promise.resolve()
  select(shiftedEditor, 5)
  typeText(shiftedEditor, ' updated')
  select(shiftedEditor, shiftedEditor.state.doc.length - 1)
  finishShifted({ title: 'Mapped Title' })
  expect(await pendingShifted).toBe(true)
  expect(exportMarkdown(shiftedEditor)).toBe(`Lead updated\n\n[Mapped Title](${url})\n\nTail`)
  expect(shiftedEditor.state.selection.head).toBe(shiftedEditor.state.doc.length - 1)

  // 4. Deleting a pending embed block leaves another same-URL embed block untouched; shifting before an embed maps cleanly.
  let finishEmbedDelete!: (meta: { title: string }) => void
  const embedDupEditor = openWithHost(`<embed href="${url}" />\n\n<embed href="${url}" />`, {
    resolveLinkMetadata: () =>
      new Promise(resolve => {
        finishEmbedDelete = resolve
      })
  })
  const pendingEmbedDelete = unfurlEmbed(embedDupEditor, url, 0)
  await Promise.resolve()
  embedDupEditor.dispatch({ changes: { from: 0, to: 1 } })
  finishEmbedDelete({ title: 'Should Not Apply To Second Embed' })
  await pendingEmbedDelete
  expect(exportMarkdown(embedDupEditor)).toBe(`<embed href="${url}" />`)

  let finishEmbedShift!: (meta: { title: string }) => void
  const embedShiftEditor = openWithHost(`Intro\n\n<embed href="${url}" />`, {
    resolveLinkMetadata: () =>
      new Promise(resolve => {
        finishEmbedShift = resolve
      })
  })
  const pendingEmbedShift = unfurlEmbed(embedShiftEditor, url, 7)
  await Promise.resolve()
  select(embedShiftEditor, 6)
  typeText(embedShiftEditor, ' extended')
  finishEmbedShift({ title: 'Shifted Embed Title' })
  await pendingEmbedShift
  expect(exportMarkdown(embedShiftEditor)).toBe(`Intro extended\n\n<embed href="${url}" title="Shifted Embed Title" />`)

  // 5. Transient null metadata responses are not permanently cached, allowing subsequent retries to resolve.
  let attempts = 0
  const retryEditor = openWithHost('', {
    resolveLinkMetadata: async () => {
      attempts++
      return attempts === 1 ? null : { title: 'Recovered Title' }
    }
  })
  expect(await fetchLinkMetadata(retryEditor, 'https://example.com/transient')).toBeNull()
  expect(await fetchLinkMetadata(retryEditor, 'https://example.com/transient')).toEqual({
    title: 'Recovered Title',
    description: undefined,
    image: undefined,
    icon: undefined
  })
  expect(attempts).toBe(2)
})
