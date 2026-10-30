import { expect, test } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { applyBlockType, blockTypeAt } from '../src/editor/block-actions'
import { filterBlockOptions } from '../src/editor/block-catalog'
import { foldedHeadings, headingSections, toggleHeading } from '../src/editor/headings'
import { changeTable } from '../src/editor/tables'
import { undo } from '../src/editor/commands'
import { insertResource, resourceChanges } from '../src/blocks/resources'
import { EmbedHref, EmbedTitle } from '../src/blocks/embed'
import {
  iframeURL,
  mediaKind,
  replaceResourceSource,
  resourceContent,
  resourceText,
  videoEmbedURL,
  webURL
} from '../src/document/resources'
import { element, type Element } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { closeFileUpload, fileUploadField } from '../src/editor/file-upload'
import { EditorContext } from '../src/react/context'
import { ResourceBlock } from '../src/react/ResourceBlocks'
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
      '<page><media kind="video" src="ankole:asset/clip.mp4" mime="video/mp4" title="Clip" /><bookmark src="https://example.com" title="Example" description="Description" image="https://example.com/image.png" view="card" /><embed href="https://www.figma.com/design/example" title="Design" /><callout tone="success" icon="✅"><p>Ready</p></callout></page>'
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

test('resource patches preserve unrelated remote metadata and remove only explicit fields', () => {
  const editor = open(
    '<bookmark src="https://example.com" title="Old" description="Remote edit" view="preview" custom="kept" />'
  )
  const before = readTree(editor)
  editor.dispatch({ changes: resourceChanges(editor.state.doc.content[0]!, 0, { title: 'Local edit' }) })
  expect(readTree(editor).children[0]).toEqual({
    type: 'element',
    name: 'bookmark',
    children: [],
    attrs: {
      src: 'https://example.com',
      title: 'Local edit',
      description: 'Remote edit',
      view: 'preview',
      custom: 'kept'
    }
  })
  undo(editor)
  expect(readTree(editor)).toEqual(before)
  editor.dispatch({ changes: resourceChanges(editor.state.doc.content[0]!, 0, { description: undefined }) })
  expect(exportMarkdown(editor)).not.toContain('description=')
  expect(exportMarkdown(editor)).toContain('view="preview"')
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
  expect(resourceText(element('bookmark', { src: 'https://example.com/report.pdf', title: 'Report' }))).toBe(
    'Report (https://example.com/report.pdf)'
  )
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
        createElement(ResourceBlock, {
          kind: 'bookmark',
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
        createElement(ResourceBlock, {
          kind: 'embed',
          attrs: { src: 'ankole:asset/applet', title: 'Relative Applet', view: 'preview' },
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
        createElement(ResourceBlock, {
          kind: 'embed',
          attrs: { src: 'https://pod.ankole.test/pod/applet-frame/123', title: 'Applet', view: 'preview' },
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
        createElement(ResourceBlock, {
          kind: 'embed',
          attrs: { src: 'https://external.example/embed/1', title: 'External', view: 'preview' },
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
