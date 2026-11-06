import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { KnowledgeReader } from '../src/reader'
import { renderKnowledgeMermaid } from '../src/react/KnowledgeReader'
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

  test('images, dividers, empty code blocks, and Mermaid blocks are content even without prose', () => {
    for (const xml of [
      '<page><p><img src="https://example.com/photo.png" alt="Photo"/></p></page>',
      '<page><media src="ankole:asset/photo" title="Photo" kind="image"/></page>',
      '<page><hr/></page>',
      '<page><pre lang="text"/></page>',
      '<page><mermaid/></page>'
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

  test('Mermaid blocks render <figure class="knowledge-reader-mermaid"><pre><code> initially and lazily render SVG with resolved theme', async () => {
    const xml = '<page><mermaid>flowchart TD\n  A[Start] --&gt; B[Finish]</mermaid></page>'
    const ssrHtml = renderToStaticMarkup(<KnowledgeReader xml={xml} />)
    expect(ssrHtml).toContain('<figure class="knowledge-reader-mermaid">')
    expect(ssrHtml).toContain('<pre><code>flowchart TD\n  A[Start] --&gt; B[Finish]</code></pre>')
    expect(ssrHtml).not.toContain('contenteditable')

    const lightContainer = {
      closest: (selector: string) =>
        selector === '[data-theme]'
          ? { getAttribute: (name: string) => (name === 'data-theme' ? 'light' : null) }
          : null
    }
    const darkContainer = {
      closest: (selector: string) =>
        selector === '[data-theme]' ? { getAttribute: (name: string) => (name === 'data-theme' ? 'dark' : null) } : null
    }

    const light = await renderKnowledgeMermaid('flowchart TD\n  A[Start] --> B[Finish]', lightContainer)
    expect(light).not.toBeNull()
    expect(light!.theme).toBe('light')
    expect(light!.svg).toContain('<svg')
    expect(light!.svg).toContain('Start')

    const dark = await renderKnowledgeMermaid('flowchart TD\n  A[Start] --> B[Finish]', darkContainer)
    expect(dark).not.toBeNull()
    expect(dark!.theme).toBe('dark')
    expect(dark!.svg).toContain('<svg')

    expect(await renderKnowledgeMermaid('', lightContainer)).toBeNull()
    expect(await renderKnowledgeMermaid('not valid mermaid syntax %%% {{{', lightContainer)).toBeNull()
  })
})
