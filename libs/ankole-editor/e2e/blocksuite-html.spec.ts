// Derived fixture data is from BlockSuite (MPL-2.0). See upstream/NOTICE.md.
import fixtures from '../upstream/fixtures/blocksuite-html.json' with { type: 'json' }
import dialect from '../upstream/fixtures/blocksuite-dialect.json' with { type: 'json' }
import { clipboard, expect, openDocument, reopen, selectDocument, test } from './helpers'

for (const fixture of fixtures) {
  test(`${fixture.id} ${fixture.name}`, async ({ page }) => {
    await openDocument(page, 'Replace me')
    await selectDocument(page)
    const body = page.locator('.editor-content')
    await clipboard(body, 'paste', { 'text/html': fixture.html })
    const difference = (dialect as Record<string, { expected: unknown[] }>)[fixture.id]
    const expected =
      difference?.expected ??
      fixture.expected.map(function convert(block): unknown {
        return {
          type: block.type,
          delta: block.delta,
          ...(block.flavour === 'affine:list' ? { children: block.children.map(convert) } : {})
        }
      })
    async function content() {
      return body.evaluate(element => {
        type Block = {
          type: string
          delta: { insert: string; attributes?: Record<string, string | boolean> }[]
          children?: Block[]
        }
        function blocks(parent: Element): Block[] {
          const result: Block[] = []
          for (const child of parent.children) {
            if (child.matches('ol,ul')) {
              result.push(...blocks(child))
              continue
            }
            // A nested list belongs to its list item. An editor may also put it in a list item of
            // its own after that item.
            const nested = child.matches('li') ? [...child.children].filter(list => list.matches('ol,ul')) : []
            if (nested.length && nested.length === child.children.length) {
              result.at(-1)!.children!.push(...nested.flatMap(blocks))
              continue
            }
            const block: Block = {
              type: child.matches('li')
                ? child.parentElement!.tagName === 'OL'
                  ? 'numbered'
                  : 'bulleted'
                : /^H[1-6]$/.test(child.tagName)
                  ? child.tagName.toLowerCase()
                  : 'text',
              delta: []
            }
            if (child.matches('li')) block.children = nested.flatMap(blocks)
            const walker = document.createTreeWalker(child, NodeFilter.SHOW_TEXT)
            while (walker.nextNode()) {
              const node = walker.currentNode as Text
              // Text in a nested list is the text of its own item.
              if (child.matches('li') && node.parentElement!.closest('li') !== child) continue
              const attributes: Record<string, string | boolean> = {}
              let parent = node.parentElement
              while (parent && parent !== child) {
                if (parent.matches('strong,b')) attributes.bold = true
                if (parent.matches('em,i')) attributes.italic = true
                if (parent.matches('u')) attributes.underline = true
                if (parent.matches('s,del')) attributes.strike = true
                if (parent.matches('a')) attributes.link = parent.getAttribute('href')!
                parent = parent.parentElement
              }
              const value = Object.keys(attributes).length ? attributes : undefined
              const previous = block.delta.at(-1)
              if (previous && JSON.stringify(previous.attributes) === JSON.stringify(value)) {
                previous.insert += node.data
              } else block.delta.push({ insert: node.data, ...(value ? { attributes: value } : {}) })
            }
            result.push(block)
          }
          return result
        }
        return blocks(element)
      })
    }
    expect(await content()).toEqual(expected)
    await reopen(page)
    expect(await content()).toEqual(expected)
  })
}
