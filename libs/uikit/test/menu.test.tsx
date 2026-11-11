import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Command, CommandGroup, CommandItem, CommandList } from '../src/components/command'
import { DropdownMenuLabel } from '../src/components/dropdown-menu'
import { MenuFooter, MenuRichItem } from '../src/components/menu'
import { attributeOf, classesOf, tagWith } from './markup'

describe('MenuRichItem', () => {
  test('lays a 44px icon tile, a 14/26 label, and a hint on a 60px edge-to-edge row', () => {
    const html = renderToStaticMarkup(
      <MenuRichItem icon={<span>H1</span>} hint="#">
        Heading 1
      </MenuRichItem>
    )
    const row = classesOf(tagWith(html, 'data-slot="menu-rich-item"'))
    expect(row).toEqual(expect.arrayContaining(['h-15', 'ps-2', 'gap-2', 'text-75', 'rounded-none']))
    expect(row).toEqual(
      expect.arrayContaining([
        'data-highlighted:bg-layer-hover',
        'aria-selected:bg-layer-hover',
        'fine-hover:hover:bg-layer-hover'
      ])
    )
    expect(classesOf(tagWith(html, 'data-slot="menu-rich-item-icon"'))).toContain('size-11')
    expect(html).toContain('data-slot="menu-rich-item-label" class="min-w-0 flex-1 truncate">Heading 1</span>')
    expect(classesOf(tagWith(html, 'data-slot="menu-rich-item-hint"'))).toEqual(
      expect.arrayContaining(['text-50', 'text-fg-tertiary'])
    )
  })

  test('becomes the option of a listbox that `render` names and leaves out the slots it was not given', () => {
    const html = renderToStaticMarkup(
      <MenuRichItem render={<button type="button" role="option" aria-selected id="slash-0" />}>Text</MenuRichItem>
    )
    const option = tagWith(html, 'id="slash-0"')
    expect(option.startsWith('<button')).toBe(true)
    expect(attributeOf(option, 'role')).toBe('option')
    // A button centres its text by default, so the row puts its label back at the start.
    expect(classesOf(option)).toEqual(expect.arrayContaining(['h-15', 'text-start']))
    expect(attributeOf(option, 'aria-selected')).toBe('true')
    expect(html).not.toContain('menu-rich-item-icon')
    expect(html).not.toContain('menu-rich-item-hint')
  })

  test('replaces the command row geometry when it renders a CommandItem, which keeps its own slot', () => {
    const html = renderToStaticMarkup(
      <Command>
        <CommandList>
          <CommandGroup heading="Basic">
            <MenuRichItem render={<CommandItem value="h1" />} icon={<span>H1</span>}>
              Heading 1
            </MenuRichItem>
          </CommandGroup>
        </CommandList>
      </Command>
    )
    const item = classesOf(tagWith(html, 'data-slot="command-item"'))
    // Tailwind emits `ps-*` and `pe-*` after `px-*`, so the rich row's 8px start wins over the item's padding.
    expect(item).toEqual(expect.arrayContaining(['h-15', 'min-h-15', 'ps-2', 'pe-4', 'text-75', 'rounded-none']))
    expect(item.some(name => ['min-h-10', 'text-sm', 'rounded-control', 'gap-2.5'].includes(name))).toBe(false)
  })
})

describe('Menu group labels and footer', () => {
  test('share one 12/20 medium secondary label across menus', () => {
    expect(
      classesOf(tagWith(renderToStaticMarkup(<DropdownMenuLabel>Mode</DropdownMenuLabel>), 'dropdown-menu-label'))
    ).toContain('menu-group-label')
    const group = renderToStaticMarkup(
      <Command>
        <CommandList>
          <CommandGroup heading="Basic" />
        </CommandList>
      </Command>
    )
    expect(classesOf(tagWith(group, 'data-slot="command-group"'))).toContain(
      '**:[[cmdk-group-heading]]:menu-group-label'
    )
  })

  test('ends a menu with a 32px footer row of 12px medium tertiary text', () => {
    const footer = classesOf(tagWith(renderToStaticMarkup(<MenuFooter>Explore</MenuFooter>), 'data-slot="menu-footer"'))
    expect(footer).toEqual(expect.arrayContaining(['h-8', 'px-4', 'text-50', 'font-medium', 'text-fg-tertiary']))
  })
})
