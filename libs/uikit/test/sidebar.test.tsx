import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { CaretRightFilled, PanelLeftRegular } from '../src/icons'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarFooterButton,
  SidebarFooterLabel,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarHeaderRow,
  SidebarInset,
  SidebarMenu,
  SidebarMenuAction,
  SidebarMenuActions,
  SidebarMenuButton,
  SidebarMenuIcon,
  SidebarMenuItem,
  SidebarMenuRow,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
  SidebarMenuToggle,
  SidebarProvider,
  SidebarSeparator,
  SidebarTrigger
} from '../src/components/sidebar'
import { Avatar, AvatarFallback } from '../src/components/avatar'
import { Spinner } from '../src/components/spinner'
import { TooltipProvider } from '../src/components/tooltip'
import { attributeOf, classesOf, pathOf, tagWith } from './markup'

function shell(children: React.ReactNode, open = true) {
  return renderToStaticMarkup(
    <TooltipProvider>
      <SidebarProvider defaultOpen={open}>
        <Sidebar variant="inset" mobileTitle="Navigation">
          {children}
        </Sidebar>
        <SidebarInset>Page</SidebarInset>
      </SidebarProvider>
    </TooltipProvider>
  )
}

describe('Sidebar shell', () => {
  test('paints the window on the ground, leaves the inset sidebar unfilled, and sets the 258px column', () => {
    const html = shell(null)
    const wrapper = tagWith(html, 'data-slot="sidebar-wrapper"')
    expect(classesOf(wrapper)).toContain('bg-ground')
    expect(attributeOf(wrapper, 'style')).toContain('--sidebar-width:var(--spacing-sidebar)')

    const inner = classesOf(tagWith(html, 'data-slot="sidebar-inner"'))
    expect(inner).not.toContain('bg-sidebar')
    expect(inner).toContain('group-data-[variant=floating]:bg-sidebar')
    // A top bar in the window moves the docked column below it.
    expect(classesOf(tagWith(html, 'data-slot="sidebar-container"'))).toContain('top-[var(--sidebar-top,0px)]')
  })

  test('draws the content card on the page fill with the surface radius, no edge, and a 20px end inset', () => {
    const card = classesOf(tagWith(shell(null), 'data-slot="sidebar-inset"'))
    expect(card).toContain('bg-background')
    expect(card).toContain('md:peer-data-[variant=inset]:rounded-t-surface')
    expect(card).toContain('md:peer-data-[variant=inset]:me-5')
    expect(card.some(name => name.includes('paper-sheet') || name.startsWith('border'))).toBe(false)
  })

  test('lays out a 44px header row with the toggle at its end, a hairline, and a 42px footer row', () => {
    const html = shell(
      <>
        <SidebarHeader>
          <SidebarHeaderRow>
            <span>Tabs</span>
            <SidebarTrigger label="Collapse sidebar" />
          </SidebarHeaderRow>
        </SidebarHeader>
        <SidebarSeparator />
        <SidebarFooter>Account</SidebarFooter>
      </>
    )
    const row = classesOf(tagWith(html, 'data-slot="sidebar-header-row"'))
    expect(row).toEqual(
      expect.arrayContaining([
        'h-11',
        'items-center',
        '[&>[data-slot=sidebar-trigger]]:ms-auto',
        '[&>[data-slot=sidebar-trigger]]:me-0.5'
      ])
    )

    const trigger = tagWith(html, 'data-slot="sidebar-trigger"')
    expect(attributeOf(trigger, 'aria-label')).toBe('Collapse sidebar')
    expect(classesOf(trigger)).toEqual(expect.arrayContaining(['size-6', "[&_svg:not([class*='size-'])]:size-6"]))
    // The default icon is Fluent's left panel mark, whose bar sits at the start.
    expect(html).toContain(pathOf(<PanelLeftRegular />))

    expect(classesOf(tagWith(html, 'data-slot="sidebar-separator"'))).toEqual(
      expect.arrayContaining(['bg-sidebar-border', 'ms-4', 'me-2'])
    )
    expect(classesOf(tagWith(html, 'data-slot="sidebar-footer"'))).toEqual(
      expect.arrayContaining(['min-h-10.5', 'items-center', 'px-2'])
    )
  })

  test('draws a 20px icon when the toggle takes the top bar button size', () => {
    const trigger = classesOf(
      tagWith(shell(<SidebarTrigger size="icon-lg" label="Expand sidebar" />), 'data-slot="sidebar-trigger"')
    )
    expect(trigger).toEqual(expect.arrayContaining(['size-9', "[&_svg:not([class*='size-'])]:size-5"]))
    expect(trigger).not.toContain("[&_svg:not([class*='size-'])]:size-6")
  })
})

describe('Sidebar menu rows', () => {
  test('gives a row 32px, a 12px start, a 20px icon 6px before a 14/26 label, and marks the current row', () => {
    const html = shell(
      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>Spaces</SidebarGroupLabel>
          <SidebarMenu>
            <SidebarMenuItem>
              <SidebarMenuButton isActive>Team goal</SidebarMenuButton>
            </SidebarMenuItem>
          </SidebarMenu>
        </SidebarGroup>
      </SidebarContent>
    )
    const label = classesOf(tagWith(html, 'data-slot="sidebar-group-label"'))
    expect(label).toEqual(expect.arrayContaining(['h-8', 'ps-3', 'text-50', 'text-fg-secondary']))

    const row = tagWith(html, 'data-slot="sidebar-menu-button"')
    expect(attributeOf(row, 'data-active')).toBe('')
    expect(classesOf(row)).toEqual(
      expect.arrayContaining([
        'nav-row',
        'h-8',
        'rounded-control',
        'gap-1.5',
        'text-75',
        'ps-[calc(var(--spacing)*3+var(--sidebar-menu-level,0)*var(--sidebar-menu-indent,calc(var(--spacing)*5)))]',
        "[&_svg:not([class*='size-'])]:size-5"
      ])
    )
  })

  test('holds a row icon in a 20px slot that draws in the primary colour, or the secondary one for an action', () => {
    const html = shell(
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton>
            <SidebarMenuIcon data-testid="place">
              <svg />
            </SidebarMenuIcon>
            <span>Team goal</span>
          </SidebarMenuButton>
        </SidebarMenuItem>
        <SidebarMenuItem>
          <SidebarMenuButton>
            <SidebarMenuIcon tone="secondary" data-testid="action">
              <svg />
            </SidebarMenuIcon>
            <span>New chat</span>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    )
    const place = tagWith(html, 'data-testid="place"')
    expect(attributeOf(place, 'data-sidebar')).toBe('menu-icon')
    expect(attributeOf(place, 'aria-hidden')).toBe('true')
    // The slot sets the colour that the row's icon reads, so the row's own states leave it primary.
    expect(classesOf(place)).toEqual(
      expect.arrayContaining(['size-5', 'shrink-0', 'text-(--nav-icon)', '[--nav-icon:var(--foreground)]'])
    )
    const action = classesOf(tagWith(html, 'data-testid="action"'))
    expect(action).toContain('[--nav-icon:var(--fg-secondary)]')
    expect(action).not.toContain('[--nav-icon:var(--foreground)]')
  })

  test('renders a group as the element that the caller names, such as a region', () => {
    const html = shell(
      <SidebarContent>
        <SidebarGroup render={<section aria-label="Spaces" />} className="extra">
          <SidebarGroupLabel>Spaces</SidebarGroupLabel>
        </SidebarGroup>
      </SidebarContent>
    )
    const group = tagWith(html, 'data-slot="sidebar-group"')
    expect(group.startsWith('<section')).toBe(true)
    expect(attributeOf(group, 'aria-label')).toBe('Spaces')
    expect(attributeOf(group, 'data-sidebar')).toBe('group')
    expect(classesOf(group)).toEqual(expect.arrayContaining(['px-2', 'pt-(--sidebar-group-gap)', 'extra']))
  })

  test('draws the header separator as a 1px hairline through the orientation that Base UI sets', () => {
    const html = shell(
      <SidebarHeader>
        <SidebarSeparator />
      </SidebarHeader>
    )
    const separator = tagWith(html, 'data-slot="sidebar-separator"')
    // Base UI marks the orientation only in `data-orientation`, so the line's size has to key on that attribute.
    expect(attributeOf(separator, 'data-orientation')).toBe('horizontal')
    expect(classesOf(separator)).toEqual(
      expect.arrayContaining([
        'data-[orientation=horizontal]:h-px',
        'data-[orientation=horizontal]:w-auto',
        'bg-sidebar-border',
        'ms-4',
        'me-2'
      ])
    )
    expect(classesOf(separator)).not.toContain('data-horizontal:h-px')
    expect(classesOf(separator)).not.toContain('h-px')
  })

  test('indents each nesting level by setting the level that child rows read', () => {
    const html = shell(
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton>Parent</SidebarMenuButton>
          <SidebarMenuSub data-testid="level-1">
            <SidebarMenuSubItem>
              <SidebarMenuSubButton href="/child">Child</SidebarMenuSubButton>
              <SidebarMenuSub data-testid="level-2" />
            </SidebarMenuSubItem>
          </SidebarMenuSub>
        </SidebarMenuItem>
        <SidebarMenuItem level={3} data-testid="flat">
          <SidebarMenuButton>Flat row</SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    )
    expect(attributeOf(tagWith(html, 'data-testid="level-1"'), 'style')).toBe('--sidebar-menu-level:1')
    expect(attributeOf(tagWith(html, 'data-testid="level-2"'), 'style')).toBe('--sidebar-menu-level:2')
    expect(attributeOf(tagWith(html, 'data-testid="flat"'), 'style')).toBe('--sidebar-menu-level:3')
    // A child row shares the row geometry, so only the level moves it.
    expect(classesOf(tagWith(html, 'data-slot="sidebar-menu-sub-button"'))).toEqual(
      expect.arrayContaining(['nav-row', 'h-8', 'text-75'])
    )
  })

  test('places a 20px arrow over the row icon slot and 24px actions after the row that wait for it', () => {
    const html = shell(
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuRow>
            <SidebarMenuToggle aria-expanded={false} aria-label="Expand" />
            <SidebarMenuButton>
              <SidebarMenuIcon>
                <svg />
              </SidebarMenuIcon>
              <span>Project</span>
            </SidebarMenuButton>
            <SidebarMenuActions>
              <SidebarMenuAction aria-label="More">•</SidebarMenuAction>
              <SidebarMenuAction aria-label="Add">+</SidebarMenuAction>
            </SidebarMenuActions>
          </SidebarMenuRow>
        </SidebarMenuItem>
        <SidebarMenuItem>
          <SidebarMenuButton>Settings</SidebarMenuButton>
          <SidebarMenuAction aria-label="Edit">e</SidebarMenuAction>
        </SidebarMenuItem>
        <SidebarMenuItem>
          <SidebarMenuButton>Trash</SidebarMenuButton>
          <SidebarMenuAction aria-label="Empty" showOnHover={false}>
            x
          </SidebarMenuAction>
        </SidebarMenuItem>
      </SidebarMenu>
    )
    const toggle = tagWith(html, 'data-slot="sidebar-menu-toggle"')
    // The arrow stays a real button in the tab order, named by its row and carrying the expanded state.
    expect(toggle.startsWith('<button')).toBe(true)
    expect(attributeOf(toggle, 'type')).toBe('button')
    expect(attributeOf(toggle, 'tabindex')).toBeUndefined()
    expect(attributeOf(toggle, 'aria-label')).toBe('Expand')
    expect(attributeOf(toggle, 'aria-expanded')).toBe('false')
    expect(attributeOf(toggle, 'data-sidebar')).toBe('menu-toggle')
    const arrow = classesOf(toggle)
    expect(arrow).toEqual(
      expect.arrayContaining([
        // It starts where the row's content starts, so it covers the icon slot instead of pushing the row.
        'start-[calc(var(--spacing)*3+var(--sidebar-menu-level,0)*var(--sidebar-menu-indent,calc(var(--spacing)*5)))]',
        'size-5',
        'rounded-control',
        'text-fg-secondary',
        'hover:bg-layer-hover',
        '[&>svg:not([data-slot=spinner])]:size-5',
        'aria-expanded:[&>svg:not([data-slot=spinner])]:rotate-90'
      ])
    )
    expect(arrow).not.toContain('size-4')
    // The button gives a parent row the same start as any other row.
    expect(html).not.toContain('--sidebar-menu-caret')
    // The default arrow is Fluent's filled caret, one glyph that turns a quarter while open.
    expect(html).toContain(pathOf(<CaretRightFilled />))

    const actions = tagWith(html, 'data-slot="sidebar-menu-actions"')
    expect(attributeOf(actions, 'data-sidebar')).toBe('menu-actions')
    // A button that another component renders into the group takes the actions' primary ink too.
    expect(classesOf(actions)).toContain('*:text-foreground')
    const grouped = tagWith(html, 'aria-label="More"')
    expect(attributeOf(grouped, 'data-reveal')).toBeUndefined()
    expect(classesOf(grouped)).toEqual(
      expect.arrayContaining(['size-6', 'text-foreground', '[&>svg:not([class*=size-])]:size-4'])
    )
    expect(classesOf(grouped)).not.toContain('absolute')

    const single = tagWith(html, 'aria-label="Edit"')
    expect(attributeOf(single, 'data-reveal')).toBe('hover')
    expect(classesOf(single)).toEqual(expect.arrayContaining(['absolute', 'end-1', 'size-6']))
    expect(attributeOf(tagWith(html, 'aria-label="Empty"'), 'data-reveal')).toBeUndefined()
  })
})

describe('Sidebar menu row', () => {
  test('keeps the arrow and the actions in the row box, so an open child list does not move them', () => {
    const html = shell(
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuRow data-testid="row">
            <SidebarMenuToggle aria-expanded aria-label="Collapse" />
            <SidebarMenuButton>Project</SidebarMenuButton>
            <SidebarMenuActions>
              <SidebarMenuAction aria-label="More">•</SidebarMenuAction>
            </SidebarMenuActions>
          </SidebarMenuRow>
          <SidebarMenuSub>
            <SidebarMenuSubItem>
              <SidebarMenuSubButton href="/child">Child</SidebarMenuSubButton>
            </SidebarMenuSubItem>
          </SidebarMenuSub>
        </SidebarMenuItem>
      </SidebarMenu>
    )
    const row = tagWith(html, 'data-testid="row"')
    expect(attributeOf(row, 'data-sidebar')).toBe('menu-row')
    expect(classesOf(row)).toContain('relative')
    // The arrow, the button, and the actions sit inside the row box, and the child list follows the box.
    const start = html.indexOf(row)
    const sub = html.indexOf('data-slot="sidebar-menu-sub"')
    for (const part of ['data-slot="sidebar-menu-toggle"', 'data-slot="sidebar-menu-button"', 'aria-label="More"']) {
      const at = html.indexOf(part)
      expect(at).toBeGreaterThan(start)
      expect(at).toBeLessThan(sub)
    }
    expect(html.slice(start, sub)).toContain('</div></div><ul')
    // The arrow and the actions centre on their nearest positioned box, which is now the row.
    expect(classesOf(tagWith(html, 'data-slot="sidebar-menu-toggle"'))).toEqual(
      expect.arrayContaining(['absolute', 'top-1/2', '-translate-y-1/2'])
    )
  })

  test('renders the row as the element that the caller names, such as a context-menu trigger', () => {
    const html = shell(
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuRow render={<section aria-label="Row" />} className="extra" />
        </SidebarMenuItem>
      </SidebarMenu>
    )
    const row = tagWith(html, 'aria-label="Row"')
    expect(row.startsWith('<section')).toBe(true)
    expect(classesOf(row)).toEqual(expect.arrayContaining(['relative', 'extra']))
  })

  test('turns only the arrow, not a 16px spinner that stands in for it while the child rows load', () => {
    const html = shell(
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuRow>
            <SidebarMenuToggle aria-expanded aria-busy aria-label="Loading">
              <Spinner aria-hidden />
            </SidebarMenuToggle>
            <SidebarMenuButton>Project</SidebarMenuButton>
          </SidebarMenuRow>
        </SidebarMenuItem>
      </SidebarMenu>
    )
    const toggle = classesOf(tagWith(html, 'data-slot="sidebar-menu-toggle"'))
    expect(toggle).toEqual(
      expect.arrayContaining([
        'aria-expanded:[&>svg:not([data-slot=spinner])]:rotate-90',
        'rtl:aria-expanded:[&>svg:not([data-slot=spinner])]:-rotate-90',
        '[&>svg[data-slot=spinner]]:size-4'
      ])
    )
    expect(toggle).not.toContain('aria-expanded:[&>svg]:rotate-90')
    expect(html).toContain('data-slot="spinner"')
  })

  test('places a caret in a section title after its text and shows it only while the title is hovered or focused', () => {
    for (const expanded of [true, false]) {
      const html = shell(
        <SidebarGroup>
          <SidebarGroupLabel>
            <a href="/spaces">Spaces</a>
            <SidebarMenuToggle aria-expanded={expanded} aria-label="Spaces" />
          </SidebarGroupLabel>
        </SidebarGroup>
      )
      expect(classesOf(tagWith(html, 'data-slot="sidebar-group-label"'))).toContain('group/sidebar-group-label')
      const caret = classesOf(tagWith(html, 'data-slot="sidebar-menu-toggle"'))
      expect(caret).toEqual(
        expect.arrayContaining([
          'relative',
          'size-4',
          'text-fg-tertiary',
          '[&>svg]:size-4',
          'fine-hover:opacity-0',
          'fine-hover:group-hover/sidebar-group-label:opacity-100',
          'fine-hover:group-focus-within/sidebar-group-label:opacity-100'
        ])
      )
      // A closed section rests on its title alone too; nothing but hover or focus shows the caret.
      expect(caret.filter(name => name.includes('opacity-100'))).toEqual([
        'fine-hover:group-hover/sidebar-group-label:opacity-100',
        'fine-hover:group-focus-within/sidebar-group-label:opacity-100'
      ])
      // The title's caret keeps its place after the text; only a row's arrow covers an icon slot.
      expect(caret).not.toContain('absolute')
      expect(caret).not.toContain('size-5')
    }
  })

  test('swaps a parent row icon for its arrow on hover, keyboard focus, and loading, and always without hover', async () => {
    const styles = await Bun.file(new URL('../src/styles.css', import.meta.url)).text()
    const compact = styles.replace(/\s+/g, ' ')
    // Every parent row hides the icon under its arrow; a screen without hover and the phone sheet keep it that way.
    expect(compact).toContain(
      "[data-sidebar='menu-row'] > [data-sidebar='menu-toggle'] + :is([data-sidebar='menu-button'], [data-sidebar='menu-sub-button']) > [data-sidebar='menu-icon'] { opacity: 0; }"
    )
    // With a fine pointer a resting row shows its icon and hides its arrow, unless the arrow is busy.
    const resting =
      "[data-sidebar='menu-row']:not( :hover, :has(> :focus-visible, > [data-sidebar='menu-actions'] :focus-visible), [data-mobile='true'] * ) > [data-sidebar='menu-toggle']:not([aria-busy='true'])"
    const fine = compact.slice(compact.indexOf(`@media (hover: hover) and (pointer: fine) { ${resting}`))
    expect(fine).toContain(`${resting} { opacity: 0; }`)
    expect(fine).toContain(
      `${resting} + :is([data-sidebar='menu-button'], [data-sidebar='menu-sub-button']) > [data-sidebar='menu-icon'] { opacity: 1; }`
    )
  })
})

describe('Sidebar phone sheet', () => {
  test('sizes rows, titles, arrows, and actions for touch and indents each level by 24px', () => {
    const html = shell(
      <SidebarGroup>
        <SidebarGroupLabel>
          <a href="/spaces">Spaces</a>
          <SidebarMenuToggle aria-expanded aria-label="Spaces" data-testid="caret" />
        </SidebarGroupLabel>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuRow>
              <SidebarMenuToggle aria-expanded={false} aria-label="Expand" data-testid="arrow" />
              <SidebarMenuButton>Project</SidebarMenuButton>
              <SidebarMenuActions>
                <SidebarMenuAction aria-label="More">•</SidebarMenuAction>
              </SidebarMenuActions>
            </SidebarMenuRow>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarGroup>
    )
    expect(classesOf(tagWith(html, 'data-slot="sidebar-menu-button"'))).toContain('in-data-[mobile=true]:min-h-10')
    expect(classesOf(tagWith(html, 'data-slot="sidebar-group-label"'))).toEqual(
      expect.arrayContaining(['in-data-[mobile=true]:min-h-10', 'in-data-[mobile=true]:[&>a]:self-stretch'])
    )
    // The arrow's 32px box moves 6px back, so the 20px arrow holds its place over the row's icon slot.
    expect(classesOf(tagWith(html, 'data-testid="arrow"'))).toEqual(
      expect.arrayContaining([
        'in-data-[mobile=true]:-ms-1.5',
        'start-[calc(var(--spacing)*3+var(--sidebar-menu-level,0)*var(--sidebar-menu-indent,calc(var(--spacing)*5)))]'
      ])
    )
    // The title's 32px box moves 8px back, so its 16px caret keeps its place after the text.
    expect(classesOf(tagWith(html, 'data-testid="caret"'))).toContain('in-data-[mobile=true]:-ms-2')
  })

  test('declares the sheet: every button at least 32px square, and a 24px indent per level', async () => {
    const source = await Bun.file(new URL('../src/components/sidebar.tsx', import.meta.url)).text()
    const sheet = /data-mobile="true"\s+className="([^"]+)"/.exec(source)?.[1].split(/\s+/) ?? []
    expect(sheet).toEqual(
      expect.arrayContaining([
        '[--sidebar-menu-indent:calc(var(--spacing)*6)]',
        '[&_button]:min-h-8',
        '[&_button]:min-w-8'
      ])
    )
    const styles = await Bun.file(new URL('../src/styles.css', import.meta.url)).text()
    // The sheet has no hover, so every row shows its actions and keeps room for 32px of them.
    expect(styles).toContain(
      "[data-mobile='true'] :is([data-sidebar='menu-action'][data-reveal='hover'], [data-sidebar='menu-actions'])"
    )
    expect(styles).toContain('--sidebar-menu-trail: --spacing(8);')
    expect(styles).toContain('--sidebar-menu-trail: --spacing(16);')
  })
})

describe('Sidebar motion', () => {
  test('docks and hides the column, the gap, and the card on one clock with per-direction timing', () => {
    const container = classesOf(tagWith(shell(null), 'data-slot="sidebar-container"'))
    expect(container).toEqual(
      expect.arrayContaining([
        // The column travels with a transform, so only the gap and the card reflow.
        'data-[side=left]:group-data-[collapsible=offcanvas]:-translate-x-full',
        'data-[side=right]:group-data-[collapsible=offcanvas]:translate-x-full',
        'group-data-[collapsible=offcanvas]:opacity-0',
        '[transition:translate_var(--duration-drawer)_var(--ease-drawer),width_var(--duration-drawer)_var(--ease-drawer),opacity_160ms_var(--ease-out)_60ms]',
        'group-data-[state=collapsed]:[transition:translate_var(--duration-dialog)_var(--ease-drawer),width_var(--duration-dialog)_var(--ease-drawer),opacity_120ms_var(--ease-out)]',
        'motion-reduce:transition-none!'
      ])
    )
    expect(container.join(' ')).not.toContain('left-[calc(var(--sidebar-width)*-1)]')
    for (const slot of ['sidebar-gap', 'sidebar-inset']) {
      expect(classesOf(tagWith(shell(null), `data-slot="${slot}"`))).toEqual(
        expect.arrayContaining(['duration-(--duration-drawer)', 'ease-drawer', 'motion-reduce:transition-none'])
      )
    }
    expect(classesOf(tagWith(shell(null), 'data-slot="sidebar-gap"'))).toContain(
      'group-data-[state=collapsed]:duration-(--duration-dialog)'
    )
    expect(classesOf(tagWith(shell(null), 'data-slot="sidebar-inset"'))).toContain(
      'peer-data-[state=collapsed]:duration-(--duration-dialog)'
    )
  })

  test('opens and closes a child list and a section body with height and opacity, and drops them once closed', () => {
    const render = (open: boolean, instant = false) =>
      shell(
        <SidebarGroup>
          <SidebarGroupContent open={open} data-testid="body">
            <SidebarMenu>
              <SidebarMenuItem>
                <SidebarMenuButton>Project</SidebarMenuButton>
                <SidebarMenuSub open={open} instant={instant} data-testid="list">
                  <SidebarMenuSubItem>
                    <SidebarMenuSubButton href="/child">Child</SidebarMenuSubButton>
                  </SidebarMenuSubItem>
                </SidebarMenuSub>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      )
    const open = render(true)
    for (const id of ['body', 'list']) {
      const group = classesOf(tagWith(open, `data-testid="${id}"`))
      expect(group).toEqual(
        expect.arrayContaining([
          'h-(--collapsible-panel-height)',
          'transition-[height,opacity]',
          'duration-(--duration-dialog)',
          'ease-out',
          'data-starting-style:h-0',
          'data-starting-style:opacity-0',
          'data-ending-style:h-0',
          'data-ending-style:opacity-0',
          'data-ending-style:[transition-duration:var(--duration-overlay),100ms]',
          // The group clips its rows only while it moves.
          'data-moving:overflow-hidden',
          'motion-reduce:transition-none'
        ])
      )
      expect(group).not.toContain('overflow-hidden')
    }
    // A group that is open when it renders shows open at once, with its rows' height.
    expect(attributeOf(tagWith(open, 'data-testid="list"'), 'style')).toContain('--collapsible-panel-height:auto')
    expect(attributeOf(tagWith(open, 'data-testid="list"'), 'style')).toContain('--sidebar-menu-level:1')
    expect(open).toContain('Child')
    // The list stays a direct child of its item, and the body of its section, with no wrapper of their own.
    expect(open).toMatch(/<\/button><ul [^>]*data-testid="list"/)
    expect(open).toMatch(/<div [^>]*data-testid="body"[^>]*><ul data-slot="sidebar-menu"/)
    // A closed group leaves the DOM.
    const closed = render(false)
    expect(closed).not.toContain('data-testid="body"')
    expect(closed).not.toContain('Child')
    // A list that opens on its own skips the motion.
    expect(classesOf(tagWith(render(true, true), 'data-testid="list"'))).toContain('transition-none')
  })

  test('turns a row arrow with the child list height, and at once for a list that opens at once', () => {
    const html = (instant: boolean) =>
      classesOf(
        tagWith(
          shell(
            <SidebarMenu>
              <SidebarMenuItem>
                <SidebarMenuRow>
                  <SidebarMenuToggle aria-expanded aria-label="Collapse" instant={instant} />
                  <SidebarMenuButton>Project</SidebarMenuButton>
                </SidebarMenuRow>
              </SidebarMenuItem>
            </SidebarMenu>
          ),
          'data-slot="sidebar-menu-toggle"'
        )
      )
    expect(html(false)).toEqual(
      expect.arrayContaining([
        '[&>svg]:duration-(--duration-overlay)',
        'aria-expanded:[&>svg]:duration-(--duration-dialog)',
        '[&>svg]:ease-out'
      ])
    )
    expect(html(false)).not.toContain('[&>svg]:transition-none')
    expect(html(true)).toContain('[&>svg]:transition-none')
  })
})

describe('Sidebar collapsed column', () => {
  test('makes the collapsed column inert until the caller shows it', () => {
    const collapsed = tagWith(shell(<SidebarContent />, false), 'data-slot="sidebar-container"')
    expect(attributeOf(collapsed, 'inert')).toBe('')
    const open = tagWith(shell(<SidebarContent />), 'data-slot="sidebar-container"')
    expect(attributeOf(open, 'inert')).toBeUndefined()
    const previewed = tagWith(
      renderToStaticMarkup(
        <TooltipProvider>
          <SidebarProvider defaultOpen={false}>
            <Sidebar variant="inset" mobileTitle="Navigation" inert={false}>
              <SidebarContent />
            </Sidebar>
          </SidebarProvider>
        </TooltipProvider>
      ),
      'data-slot="sidebar-container"'
    )
    expect(attributeOf(previewed, 'inert')).toBeUndefined()
  })

  test('scrolls the rows with the thin menu thumb instead of an undefined class', () => {
    const content = classesOf(tagWith(shell(<SidebarContent />), 'data-slot="sidebar-content"'))
    expect(content).toContain('menu-scrollbar')
    expect(content).not.toContain('no-scrollbar')
  })
})

describe('Sidebar footer row', () => {
  test('lays out a 42px navigation row with a 26px avatar, a name and a handle, and an 18px tertiary icon', () => {
    const html = shell(
      <SidebarFooter>
        <SidebarFooterButton aria-label="Account">
          <Avatar>
            <AvatarFallback>HP</AvatarFallback>
          </Avatar>
          <SidebarFooterLabel>
            <span>Harbor Pod</span>
            <small>Alice</small>
          </SidebarFooterLabel>
          <svg aria-hidden />
        </SidebarFooterButton>
      </SidebarFooter>
    )
    const button = tagWith(html, 'aria-label="Account"')
    expect(button.startsWith('<button')).toBe(true)
    expect(classesOf(button)).toEqual(
      expect.arrayContaining([
        'nav-row',
        'h-10.5',
        'gap-1',
        'pe-1',
        'data-popup-open:bg-layer-hover',
        '*:data-[slot=avatar]:size-6.5',
        '[&>[data-slot=avatar]_[data-slot=avatar-fallback]]:text-50',
        '[&>svg:last-child]:size-4.5',
        '[&>svg:last-child]:text-fg-secondary'
      ])
    )
    expect(classesOf(tagWith(html, 'data-slot="sidebar-footer-label"'))).toEqual(
      expect.arrayContaining(['text-75', '*:truncate', '[&>small]:text-50', '[&>small]:text-fg-secondary'])
    )
  })
})
