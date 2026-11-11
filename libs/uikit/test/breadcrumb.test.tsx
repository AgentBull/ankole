import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  Breadcrumb,
  BreadcrumbEllipsis,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator
} from '../src/components/breadcrumb'
import { attributeOf, classesOf, tagWith } from './markup'

function path() {
  return renderToStaticMarkup(
    <Breadcrumb aria-label="Page path">
      <BreadcrumbList>
        <BreadcrumbItem>
          <BreadcrumbLink render={<a href="/pages/root" />}>
            <span>Root</span>
          </BreadcrumbLink>
        </BreadcrumbItem>
        <BreadcrumbSeparator />
        <BreadcrumbItem>
          <BreadcrumbEllipsis label="More pages" render={<button type="button" />} />
        </BreadcrumbItem>
        <BreadcrumbSeparator />
        <BreadcrumbItem>
          <BreadcrumbPage>
            <span>Current</span>
          </BreadcrumbPage>
        </BreadcrumbItem>
      </BreadcrumbList>
    </Breadcrumb>
  )
}

describe('Breadcrumb', () => {
  test('is a named navigation landmark of 12px secondary crumbs, 4px apart', () => {
    const html = path()
    expect(attributeOf(tagWith(html, 'data-slot="breadcrumb"'), 'aria-label')).toBe('Page path')
    expect(classesOf(tagWith(html, 'data-slot="breadcrumb-list"'))).toEqual(
      expect.arrayContaining(['text-50', 'text-fg-secondary', 'gap-1'])
    )
  })

  test('links earlier places, marks the open place, and separates crumbs with a tertiary slash', () => {
    const html = path()
    const link = tagWith(html, 'data-slot="breadcrumb-link"')
    expect(link.startsWith('<a')).toBe(true)
    expect(attributeOf(link, 'href')).toBe('/pages/root')
    expect(classesOf(link)).toEqual(expect.arrayContaining(['hover:text-foreground', '[&>span]:truncate']))

    expect(attributeOf(tagWith(html, 'data-slot="breadcrumb-page"'), 'aria-current')).toBe('page')

    expect(html.match(/data-slot="breadcrumb-separator"/g)).toHaveLength(2)
    expect(html).toContain('aria-hidden="true" class="shrink-0 text-fg-tertiary">/</li>')
  })

  test('folds middle crumbs into a 14px ellipsis that names them and can open a menu', () => {
    const html = path()
    const ellipsis = tagWith(html, 'data-slot="breadcrumb-ellipsis"')
    expect(ellipsis.startsWith('<button')).toBe(true)
    expect(classesOf(ellipsis)).toEqual(expect.arrayContaining(['text-75', 'text-fg-secondary']))
    expect(html).toContain('<span aria-hidden="true">...</span><span class="sr-only">More pages</span>')
  })
})
