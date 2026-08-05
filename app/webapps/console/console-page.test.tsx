import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { PageStack } from './console-page'

describe('PageStack', () => {
  test('keeps its grid track shrinkable on narrow pages', () => {
    const html = renderToStaticMarkup(<PageStack>Content</PageStack>)

    expect(html).toContain('grid-cols-[minmax(0,1fr)]')
    expect(html).toContain('[&amp;&gt;*]:min-w-0')
  })
})
