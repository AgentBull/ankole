import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Toggle } from '../src/components/toggle'
import { classesOf, tagWith } from './markup'

test('sizes a shell toolbar toggle at 36px and tints only the box of its 20px icon', () => {
  const html = renderToStaticMarkup(
    <Toggle size="icon-lg" aria-label="Comments" pressed>
      <svg />
    </Toggle>
  )

  const toggle = classesOf(tagWith(html, 'aria-label="Comments"'))
  expect(toggle).toEqual(expect.arrayContaining(['size-9', 'p-1.75', 'bg-clip-content']))
  expect(toggle).toContain("[&_svg:not([class*='size-'])]:size-5")
  expect(toggle).toContain('rounded-[calc(var(--radius-micro)+var(--spacing)*2)]')
  expect(toggle).not.toContain('h-8')
})
