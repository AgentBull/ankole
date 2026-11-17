import { expect, test } from './helpers'

type EmbedLifetime = {
  configure(props: string): void
  remoteView(view: string): void
  remove(): void
  snapshot(): {
    mounts: number
    disposals: number
    sameFrame: boolean
    input: string
    scroll: number
    props?: string
    view?: string
  }
}
type EmbedWindow = Window & { embedLifetime: EmbedLifetime }

test('parameter changes preserve the mounted iframe, input, and scroll while merging remote attributes', async ({
  page
}) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'This fixture imports development modules.'
  )
  await page.goto('/playground/embedded.html')
  await expect(page.getByRole('textbox', { name: 'Second document', exact: true })).toBeVisible()
  await page.evaluate(async () => {
    const core = '/src/core/editor/index.ts'
    const extension = '/src/editor/extension.ts'
    const host = '/src/editor/host.ts'
    const xml = '/src/document/xml.ts'
    const embeds = '/src/blocks/embed/index.ts'
    const { Wordgard }: typeof import('../src/core/editor') = await import(core)
    const { initialState, editorExtension }: typeof import('../src/editor/extension') = await import(extension)
    const { hostExtension }: typeof import('../src/editor/host') = await import(host)
    const { parseXml }: typeof import('../src/document/xml') = await import(xml)
    const { embedAttributes, embedChanges }: typeof import('../src/blocks/embed') = await import(embeds)
    for (const child of document.body.children) if (child instanceof HTMLElement) child.hidden = true
    let mounts = 0
    let disposals = 0
    let configure: (props: { props: string }) => void
    let frame: HTMLIFrameElement
    let current: { props?: string; view?: string }
    let ready: Promise<void>
    const editor = Wordgard.create({
      state: initialState(parseXml(`<page><embed ref="report" props='{"region":"East"}' /><p /></page>`), [
        hostExtension({
          mountEmbed(attributes, container, update) {
            mounts++
            current = attributes
            configure = update
            frame = document.createElement('iframe')
            frame.title = 'Embedded report'
            ready = new Promise(resolve => frame.addEventListener('load', () => resolve(), { once: true }))
            frame.srcdoc = '<input aria-label="Draft" /><div style="height:2000px"></div>'
            container.append(frame)
            return {
              update(next) {
                current = next
              },
              dispose() {
                disposals++
                frame.remove()
              }
            }
          }
        }),
        editorExtension()
      ])
    })
    document.body.append(editor.dom)
    editor.flush()
    await ready!
    const original = frame!
    original.contentDocument!.querySelector('input')!.value = 'unsaved form value'
    original.contentWindow!.scrollTo(0, 120)
    ;(window as unknown as EmbedWindow).embedLifetime = {
      configure(props) {
        configure!({ props })
        editor.flush()
      },
      remoteView(view) {
        editor.dispatch({ changes: embedChanges(editor.state.doc.content[0]!, 0, { view }) })
        editor.flush()
      },
      remove() {
        editor.dispatch({ changes: { from: 0, to: 1 } })
        editor.flush()
      },
      snapshot() {
        const attrs = editor.state.doc.content[0] ? embedAttributes(editor.state.doc.content[0]) : {}
        return {
          mounts,
          disposals,
          sameFrame: original.isConnected && document.querySelector('iframe') === original,
          input: original.contentDocument?.querySelector('input')?.value ?? '',
          scroll: original.contentWindow?.scrollY ?? 0,
          props: current?.props,
          view: attrs.view
        }
      }
    }
  })
  await page.evaluate(() => {
    const embed = (window as unknown as EmbedWindow).embedLifetime
    embed.remoteView('remote-view')
    embed.configure('{"region":"South"}')
  })
  expect(await page.evaluate(() => (window as unknown as EmbedWindow).embedLifetime.snapshot())).toEqual({
    mounts: 1,
    disposals: 0,
    sameFrame: true,
    input: 'unsaved form value',
    scroll: 120,
    props: '{"region":"South"}',
    view: 'remote-view'
  })
  await page.evaluate(() => (window as unknown as EmbedWindow).embedLifetime.remove())
  await expect
    .poll(() => page.evaluate(() => (window as unknown as EmbedWindow).embedLifetime.snapshot().disposals))
    .toBe(1)
  await expect(page.locator('iframe')).toHaveCount(0)
})
