import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { FilterDisclosure } from './brain-shared'

describe('Brain filter disclosure', () => {
  test('keeps active advanced filters visible without opening the field panel', () => {
    const html = renderToStaticMarkup(
      <FilterDisclosure
        filters={[
          {
            id: 'store',
            label: 'Store',
            value: 'shared',
            onRemove: () => {}
          }
        ]}>
        <span>Advanced field panel</span>
      </FilterDisclosure>
    )

    expect(html).toContain('aria-expanded="false"')
    expect(html).toContain('Store: shared')
    expect(html).not.toContain('Advanced field panel')
  })
})
