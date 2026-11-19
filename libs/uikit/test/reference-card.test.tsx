import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { ReferenceCard } from '../src/components/reference-card'
import { attributeOf, classesOf, tagWith } from './markup'

describe('ReferenceCard', () => {
  test('is an inline outline chip 28px tall that sits on the middle of a text line', () => {
    const html = renderToStaticMarkup(
      <ReferenceCard href="/pages/q4" mark={<svg data-mark="" />}>
        Q4 roadmap
      </ReferenceCard>
    )
    const card = tagWith(html, 'href="/pages/q4"')
    expect(card.startsWith('<a ')).toBe(true)
    expect(classesOf(card)).toEqual(
      expect.arrayContaining([
        'surface-outline',
        'inline-flex',
        'h-7',
        'py-0',
        'max-w-[min(318px,100%)]',
        'align-[calc(0.38em-10px)]',
        'hover:bg-layer-hover'
      ])
    )
  })

  test('names the link by its title alone: the mark and the chevron are decoration', () => {
    const html = renderToStaticMarkup(
      <ReferenceCard href="/pages/q4" mark={<svg data-mark="" />}>
        Q4 roadmap
      </ReferenceCard>
    )
    expect(attributeOf(tagWith(html, 'data-slot="reference-card-mark"'), 'aria-hidden')).toBe('true')
    expect(attributeOf(tagWith(html, 'data-slot="reference-card-chevron"'), 'aria-hidden')).toBe('true')
    expect(html).toMatch(/data-slot="reference-card-title"[^>]*>Q4 roadmap<\/span>/)
    expect(classesOf(tagWith(html, 'data-slot="reference-card-title"'))).toEqual(
      expect.arrayContaining(['truncate', 'font-medium'])
    )
  })

  test('renders through the caller’s own link element', () => {
    const html = renderToStaticMarkup(
      <ReferenceCard render={<a href="/router/q4" data-router="" />} mark={null} className="extra">
        Q4 roadmap
      </ReferenceCard>
    )
    const card = tagWith(html, 'data-router=""')
    expect(attributeOf(card, 'href')).toBe('/router/q4')
    expect(classesOf(card)).toEqual(expect.arrayContaining(['surface-outline', 'extra']))
    expect(html).toContain('Q4 roadmap')
  })
})
