import { expect, test } from '@playwright/test'

test('Applet comment jumps highlight only a unique visible instance in the captured revision', async ({ page }) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  await expect(page.locator('[data-current]')).toHaveText('1')
  const result = await page.evaluate(async () => {
    const module = '/pod/applet-elements.ts'
    const { captureAppletElement, revealAppletElement }: typeof import('../pod/applet-elements') = await import(module)
    const rendered = document.querySelector<HTMLElement>('[data-current]')!
    rendered.dataset.ankoleSrc = 'src/App.tsx:12'
    const component = captureAppletElement(rendered, 4).anchor
    const list = document.createElement('section')
    // A container and its child can share a JSX source line and the child's visible text.
    list.dataset.ankoleSrc = 'src/OrderList.tsx:48'
    list.innerHTML =
      '<span data-ankole-src="src/OrderList.tsx:48">待发货</span><span data-ankole-src="src/OrderList.tsx:48">已发货</span>'
    document.body.append(list)
    const first = list.children[0] as HTMLElement
    const second = list.children[1] as HTMLElement
    const { anchor, quote } = captureAppletElement(first, 4)
    list.prepend(second)
    const unique = revealAppletElement(document, anchor, 4) === first
    const stale = revealAppletElement(document, anchor, 5)
    second.textContent = '待发货'
    const duplicate = revealAppletElement(document, anchor, 4)
    second.hidden = true
    const visibleOnly = revealAppletElement(document, anchor, 4) === first
    first.textContent = 'Cancelled'
    const missing = revealAppletElement(document, anchor, 4)
    const malformed = revealAppletElement(document, { ...anchor, selector: '[' }, 4)
    list.remove()
    return {
      source: anchor.source,
      quote,
      component: component.component,
      unique,
      stale,
      duplicate,
      visibleOnly,
      missing,
      malformed
    }
  })
  expect(result).toMatchObject({
    source: 'src/OrderList.tsx:48',
    quote: '待发货',
    unique: true,
    stale: null,
    duplicate: null,
    visibleOnly: true,
    missing: null,
    malformed: null
  })
  expect(result.component).toContain('App')
})
