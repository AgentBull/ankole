import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { DialogFooter } from '../src/components/dialog'
import { Button } from '../src/components/button'

describe('DialogFooter', () => {
  test('keeps dialog actions compact and right aligned', () => {
    const html = renderToStaticMarkup(
      <DialogFooter>
        <button data-slot="dialog-close">Cancel</button>
        <Button>Confirm</Button>
      </DialogFooter>
    )

    expect(html).toContain('justify-end')
    expect(html).toContain('gap-2')
    expect(html).not.toContain('flex-1')
  })
})
