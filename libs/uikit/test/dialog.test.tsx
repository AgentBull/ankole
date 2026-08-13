import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Dialog, DialogFooter } from '../src/components/dialog'

describe('DialogFooter', () => {
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
