import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { KnowledgeReader } from '../src/reader'
import corpus from '../corpus/knowledge.json'

describe('knowledge reading without an editor', () => {
  test('empty documents occupy no reading surface', () => {
    for (const xml of ['<page/>', '<page><p/></page>', '<page><p><strong> </strong><br/></p></page>']) {
      expect(renderToStaticMarkup(<KnowledgeReader xml={xml} />)).toBe('')
    }
  })

  test('every supported knowledge corpus document renders without editor state or controls', () => {
    for (const fixture of corpus) {
      const html = renderToStaticMarkup(<KnowledgeReader xml={fixture.xml} />)
      expect(html).not.toContain('contenteditable')
      expect(html).not.toContain('<wg-')
      expect(html).not.toContain('editor-toolbar')
    }
  })

  test('images, dividers and empty code blocks are content even without text', () => {
    for (const xml of [
      '<page><p><img src="https://example.com/photo.png" alt="Photo"/></p></page>',
      '<page><media src="ankole:asset/photo" title="Photo" kind="image"/></page>',
      '<page><hr/></page>',
      '<page><pre lang="text"/></page>'
    ]) {
      const html = renderToStaticMarkup(
        <KnowledgeReader xml={xml} host={{ resolveAsset: () => 'https://example.com/uploaded.png' }} />
      )
      expect(html).toContain('data-knowledge-reader')
    }
  })

  test('reading preserves navigation, resources, code, callouts and semantic tables', () => {
    const xml =
      '<page><h2>Terms</h2><p><a href="ankole:page/target">Original label</a><mention principal="alice"/></p>' +
      '<media src="ankole:asset/photo" title="Product" description="Side view" kind="image"/>' +
      '<callout tone="warning" icon="!"><p>Check freight.</p></callout>' +
      '<pre lang="js">const x = &lt;value&gt;;\n  next()</pre>' +
      '<table><tr><th align="right"><p>Price</p></th></tr><tr><td><p>32</p></td></tr></table>' +
      '<ol start="3"><li task="done"><p>Confirmed</p></li></ol></page>'
    const html = renderToStaticMarkup(
      <KnowledgeReader
        xml={xml}
        pageHref={id => `/pages/${id}`}
        host={{ resolveAsset: () => 'https://example.com/product.png', mentionText: () => 'Alice' }}
      />
    )
    expect(html).toContain('href="/pages/target"')
    expect(html).toContain('Original label')
    expect(html).toContain('Alice')
    expect(html).toContain('src="https://example.com/product.png"')
    expect(html).toContain('Side view')
    expect(html).toContain('data-tone="warning"')
    expect(html).toContain('const x = &lt;value&gt;;\n  next()')
    expect(html).toContain('<thead>')
    expect(html).toContain('scope="col"')
    expect(html).toContain('text-align:right')
    expect(html).toContain('start="3"')
    expect(html).toContain('type="checkbox"')
    expect(html).toContain('checked=""')
  })
})
