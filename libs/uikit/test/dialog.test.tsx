import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Dialog, DialogFooter } from '../src/components/dialog'
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

  test('uses the supplied label for its built-in close action', () => {
    const html = renderToStaticMarkup(
      <Dialog>
        <DialogFooter closeLabel="关闭" showCloseButton />
      </Dialog>
    )

    expect(html).toContain('>关闭</button>')
    expect(html).not.toContain('>Close</button>')
  })
})
