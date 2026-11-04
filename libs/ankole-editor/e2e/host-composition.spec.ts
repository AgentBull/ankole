import type { Page } from '@playwright/test'
import { expect, test } from './helpers'

type HostComposition = {
  update(view: string): Promise<void>
  remote(operation: 'shift' | 'delete' | 'replace', updateBeforeFlush?: boolean): void
  readOnly(value: boolean): void
  finish(): void
  reconnect(): void
  undo(): void
  redo(): void
  snapshot(): { composing: boolean; xml: string; views: Record<string, string | undefined> }
}
type HostWindow = Window & { hostComposition: HostComposition }

async function mount(page: Page) {
  await page.goto('/playground/embedded.html')
  await expect(page.getByRole('textbox', { name: 'Second document', exact: true })).toBeVisible()
  await page.evaluate(async () => {
    const core = '/src/core/editor/index.ts'
    const state = '/src/core/state/index.ts'
    const extension = '/src/editor/extension.ts'
    const host = '/src/editor/host.ts'
    const xml = '/src/document/xml.ts'
    const embeds = '/src/blocks/embed/index.ts'
    const source = '/src/editor/page-update.ts'
    const convert = '/src/editor/convert.ts'
    const commands = '/src/editor/commands.ts'
    const { Wordgard }: typeof import('../src/core/editor') = await import(core)
    const { GardState, Transaction }: typeof import('../src/core/state') = await import(state)
    const { initialState, editorExtension }: typeof import('../src/editor/extension') = await import(extension)
    const { hostExtension }: typeof import('../src/editor/host') = await import(host)
    const { parseXml }: typeof import('../src/document/xml') = await import(xml)
    const { Embed, embedAttributes }: typeof import('../src/blocks/embed') = await import(embeds)
    const { validatedPageSource }: typeof import('../src/editor/page-update') = await import(source)
    const { pageDocument }: typeof import('../src/editor/convert') = await import(convert)
    const { undo, redo }: typeof import('../src/editor/commands') = await import(commands)
    const updates = new Map<string, (attributes: { ref: string; view: string }) => void>()
    const editable = GardState.Compartment.define()
    document.body.replaceChildren()
    const editor = Wordgard.create({
      state: initialState(
        parseXml(
          '<page><ul><li><p /></li></ul><embed ref="tasks" view="initial"/><embed ref="sibling" view="kept"/></page>'
        ),
        [
          hostExtension({
            mountEmbed(attributes, dom, update) {
              dom.textContent = attributes.ref ?? ''
              updates.set(attributes.ref!, update)
            }
          }),
          editorExtension(),
          editable.of([])
        ]
      )
    })
    document.body.append(editor.dom)
    editor.dispatch({ selection: { anchor: 3 } })
    editor.flush()
    editor.focus()
    ;(window as unknown as HostWindow).hostComposition = {
      async update(view) {
        // This host callback models FieldEditorButton's post-refresh onCreated callback, not the HTTP flow.
        const callback = updates.get('tasks')!
        await Promise.resolve()
        const next = { ref: 'tasks', view }
        callback(next)
        next.view = 'mutated after the callback'
      },
      remote(operation, updateBeforeFlush) {
        let position = -1
        editor.state.doc.iterate((node, pos) => {
          if (node.type === Embed.type && embedAttributes(node).ref === 'tasks') position = pos
        })
        editor.dispatch({
          changes:
            operation === 'shift'
              ? { from: position, insert: pageDocument(parseXml('<page><p>Remote</p></page>')).content }
              : {
                  from: position,
                  to: position + 1,
                  insert:
                    operation === 'delete'
                      ? []
                      : pageDocument(parseXml('<page><embed ref="tasks" view="remote"/></page>')).content
                },
          annotations: [Transaction.remote.of(true), Transaction.addToHistory.of(false)]
        })
        if (updateBeforeFlush) updates.get('tasks')!({ ref: 'tasks', view: 'stale' })
        editor.flush()
      },
      readOnly(value) {
        editor.dispatch({ effects: editable.reconfigure([GardState.readOnly.of(value), Wordgard.editable.of(!value)]) })
      },
      finish() {
        if (editor.inputState.composing) editor.inputState.clearComposition()
        editor.flush()
        editor.inputState.finishComposition()
      },
      reconnect() {
        editor.dom.remove()
        document.body.append(editor.dom)
      },
      undo() {
        undo(editor)
        editor.flush()
      },
      redo() {
        redo(editor)
        editor.flush()
      },
      snapshot() {
        const views: Record<string, string | undefined> = {}
        editor.state.doc.iterate(node => {
          if (node.type === Embed.type) {
            const attrs = embedAttributes(node)
            views[attrs.ref!] = attrs.view
          }
        })
        return { composing: editor.composing, xml: validatedPageSource(editor.state.doc).xml, views }
      }
    }
  })
}

async function snapshot(page: Page) {
  return page.evaluate(() => (window as unknown as HostWindow).hostComposition.snapshot())
}

test.beforeEach(({ browserName }) => {
  test.skip(browserName !== 'chromium', 'Chromium CDP supplies browser composition; this is not OS IME acceptance.')
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'This fixture imports development modules.'
  )
})

for (const cancel of [false, true]) {
  test(`an async inline field configuration stays separate from the complete IME ${cancel ? 'cancellation' : 'commit'} undo step`, async ({
    page
  }) => {
    await mount(page)
    const initial = (await snapshot(page)).xml
    const client = await page.context().newCDPSession(page)
    try {
      await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
      await page.evaluate(() =>
        (window as unknown as HostWindow).hostComposition.update('{"type":"grid","visible_fields":["old","created"]}')
      )
      expect((await snapshot(page)).composing).toBe(true)
      if (cancel) await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
      else await client.send('Input.insertText', { text: '中' })
      await expect.poll(async () => (await snapshot(page)).views.tasks).toContain('created')
      await page.evaluate(() => (window as unknown as HostWindow).hostComposition.undo())
      expect((await snapshot(page)).views.tasks).toBe('initial')
      expect((await snapshot(page)).xml).toContain(cancel ? '<li />' : '<p>中</p>')
      await page.evaluate(() => (window as unknown as HostWindow).hostComposition.undo())
      expect((await snapshot(page)).xml).toBe(initial)
      await page.evaluate(() => {
        const host = (window as unknown as HostWindow).hostComposition
        host.redo()
        host.redo()
      })
      expect((await snapshot(page)).xml).toContain(cancel ? '<li />' : '<p>中</p>')
      expect((await snapshot(page)).views.tasks).toContain('created')
    } finally {
      await client.detach()
    }
  })
}

test('two deferred embed updates follow a shifted target and keep both undo steps', async ({ page }) => {
  await mount(page)
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
    await page.evaluate(async () => {
      const host = (window as unknown as HostWindow).hostComposition
      await host.update('first')
      await host.update('second')
      host.remote('shift')
    })
    expect((await snapshot(page)).views.tasks).toBe('initial')
    await client.send('Input.insertText', { text: '中' })
    await expect.poll(async () => (await snapshot(page)).views.tasks).toBe('second')
    for (const view of ['first', 'initial']) {
      await page.evaluate(() => (window as unknown as HostWindow).hostComposition.undo())
      expect((await snapshot(page)).views.tasks).toBe(view)
      expect((await snapshot(page)).xml).toContain('<p>中</p>')
      expect((await snapshot(page)).xml).toContain('<p>Remote</p>')
    }
    await page.evaluate(() => (window as unknown as HostWindow).hostComposition.undo())
    expect((await snapshot(page)).xml).not.toContain('zh')
    expect((await snapshot(page)).xml).not.toContain('中')
    expect((await snapshot(page)).views.sibling).toBe('kept')
  } finally {
    await client.detach()
  }
})

for (const operation of ['delete', 'replace'] as const) {
  for (const updateBeforeFlush of [false, true]) {
    test(`an embed ${operation} discards ${updateBeforeFlush ? 'an old unflushed callback' : 'its deferred configuration'}`, async ({
      page
    }) => {
      await mount(page)
      const client = await page.context().newCDPSession(page)
      try {
        await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
        await page.evaluate(
          async ({ operation, updateBeforeFlush }) => {
            const host = (window as unknown as HostWindow).hostComposition
            if (!updateBeforeFlush) await host.update('stale')
            host.remote(operation, updateBeforeFlush)
          },
          { operation, updateBeforeFlush }
        )
        await client.send('Input.insertText', { text: '中' })
        const result = await snapshot(page)
        expect(result.views.tasks).toBe(operation === 'delete' ? undefined : 'remote')
        expect(result.views.sibling).toBe('kept')
        expect(result.xml).not.toContain('stale')
      } finally {
        await client.detach()
      }
    })
  }
}

for (const ending of ['read-only', 'disconnect'] as const) {
  test(`${ending} discards deferred embed updates before editing resumes without a DOM compositionend`, async ({
    page
  }) => {
    await mount(page)
    const client = await page.context().newCDPSession(page)
    try {
      await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
      await page.evaluate(async ending => {
        const host = (window as unknown as HostWindow).hostComposition
        await host.update('stale')
        if (ending === 'read-only') host.readOnly(true)
        else {
          const late = host.update('late stale callback')
          host.reconnect()
          await late
        }
        host.finish()
        host.readOnly(false)
        host.finish()
      }, ending)
      expect((await snapshot(page)).views.tasks).toBe('initial')
      await page.evaluate(() => (window as unknown as HostWindow).hostComposition.update('fresh'))
      expect((await snapshot(page)).views.tasks).toBe('fresh')
      expect((await snapshot(page)).xml).not.toContain('stale')
    } finally {
      await client.detach()
    }
  })
}
