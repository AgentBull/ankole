import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'

import { Badge } from '../src/components/badge'
import { Card } from '../src/components/card'
import { Ceramic } from '../src/components/ceramic'

describe('Ceramic', () => {
  test('renders a secondary-tier surface by default', () => {
    const html = renderToStaticMarkup(<Ceramic>Body</Ceramic>)
    expect(html).toContain('data-slot="ceramic"')
    expect(html).toContain('data-ceramic="secondary"')
    expect(html).toContain('class="ceramic"')
  })

  test('puts the material on a display component, which gives up its own fill and edge', () => {
    const html = renderToStaticMarkup(<Ceramic tier="primary" render={<Card />} />)
    expect(html).toContain('data-slot="card"')
    expect(html).toMatch(/class="[^"]*\bceramic ceramic-primary\b/)
    expect(html).not.toMatch(/\bbg-page\b|\bring-1\b|\bring-border-subtle\b/)
  })

  test('keeps a badge pill-shaped and amber-tinted when asked', () => {
    const html = renderToStaticMarkup(<Ceramic radius="full" attention render={<Badge>Needs you</Badge>} />)
    expect(html).toContain('ceramic-attention')
    expect(html).toContain('[--ceramic-radius:9999px]')
    expect(html).not.toMatch(/\bbg-layer-03\b|\brounded-full\b/)
  })
})
