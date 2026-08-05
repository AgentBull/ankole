import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Drawer, DrawerOverlay } from '../src/components/drawer'

describe('DrawerOverlay', () => {
  test('uses the standard short opacity transition without a backdrop blur', () => {
    const html = renderToStaticMarkup(
      <Drawer open>
        <DrawerOverlay />
      </Drawer>
    )

    expect(html).toContain('transition-opacity duration-150')
    expect(html).toContain('bg-black/60')
    expect(html).not.toContain('backdrop-blur')
    expect(html).not.toContain('duration-450')
  })
})
