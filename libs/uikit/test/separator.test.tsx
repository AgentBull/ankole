import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Separator } from '../src/components/separator'
import { attributeOf, classesOf, tagWith } from './markup'

describe('Separator', () => {
  test('sizes its line from the data-orientation attribute that Base UI writes', () => {
    for (const [orientation, size] of [
      ['horizontal', ['data-[orientation=horizontal]:h-px', 'data-[orientation=horizontal]:w-full']],
      ['vertical', ['data-[orientation=vertical]:w-px', 'data-[orientation=vertical]:self-stretch']]
    ] as const) {
      const separator = tagWith(renderToStaticMarkup(<Separator orientation={orientation} />), 'data-slot="separator"')
      expect(attributeOf(separator, 'data-orientation')).toBe(orientation)
      // Base UI sets no `data-horizontal` or `data-vertical` attribute, so variants keyed on them never apply.
      expect(attributeOf(separator, `data-${orientation}`)).toBeUndefined()
      expect(classesOf(separator)).toEqual(expect.arrayContaining(['bg-divider', ...size]))
      expect(classesOf(separator).some(name => /^data-(horizontal|vertical):/.test(name))).toBe(false)
    }
  })
})
