import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { SidebarProvider } from '../src/components/sidebar'
import { TopBar, TopBarActions, TopBarHistory, TopBarLeading, TopBarTitle } from '../src/components/top-bar'
import { attributeOf, classesOf, tagWith } from './markup'

function bar() {
  return (
    <TopBar>
      <TopBarLeading>Mark</TopBarLeading>
      <TopBarHistory aria-label="History">Back Forward</TopBarHistory>
      <TopBarTitle>Path</TopBarTitle>
      <TopBarActions>Share</TopBarActions>
    </TopBar>
  )
}

describe('TopBar', () => {
  test('is a 44px band that ends 20px before the window edge, and moves a docked sidebar below itself', () => {
    const html = renderToStaticMarkup(<SidebarProvider>{bar()}</SidebarProvider>)
    expect(classesOf(tagWith(html, 'data-slot="top-bar"'))).toEqual(
      expect.arrayContaining(['h-top-bar', 'items-center', 'pe-5'])
    )
    expect(classesOf(tagWith(html, 'data-slot="sidebar-wrapper"'))).toContain(
      'has-data-[slot=top-bar]:[--sidebar-top:var(--spacing-top-bar)]'
    )
  })

  test('spans the sidebar column with its leading zone only while the sidebar is docked open', () => {
    const open = tagWith(renderToStaticMarkup(<SidebarProvider>{bar()}</SidebarProvider>), 'top-bar-leading')
    expect(attributeOf(open, 'data-docked')).toBe('')
    expect(classesOf(open)).toContain('data-docked:min-w-[calc(var(--sidebar-width)-var(--spacing)*2)]')

    const collapsed = renderToStaticMarkup(<SidebarProvider defaultOpen={false}>{bar()}</SidebarProvider>)
    expect(attributeOf(tagWith(collapsed, 'top-bar-leading'), 'data-docked')).toBeUndefined()

    // Without a sidebar the bar still renders, and its leading zone is as wide as its content.
    const alone = renderToStaticMarkup(bar())
    expect(attributeOf(tagWith(alone, 'top-bar-leading'), 'data-docked')).toBeUndefined()
  })

  test('moves the leading zone on the sidebar clock and hides the sidebar toggle while the sidebar is docked', () => {
    const leading = classesOf(
      tagWith(renderToStaticMarkup(<SidebarProvider>{bar()}</SidebarProvider>), 'top-bar-leading')
    )
    expect(leading).toEqual(
      expect.arrayContaining([
        'transition-[min-width]',
        'duration-(--duration-dialog)',
        'data-docked:duration-(--duration-drawer)',
        'ease-drawer',
        // The toggle fades and grows in from 100ms into a hide, and leaves within 80ms of a dock.
        '[&>[data-slot=sidebar-trigger]]:[transition:opacity_160ms_var(--ease-out)_100ms,scale_160ms_var(--ease-out)_100ms,visibility_0s_100ms,background-color_var(--duration-feedback)_var(--ease-productive),color_var(--duration-feedback)_var(--ease-productive)]',
        'data-docked:[&>[data-slot=sidebar-trigger]]:invisible',
        'data-docked:[&>[data-slot=sidebar-trigger]]:opacity-0',
        'data-docked:[&>[data-slot=sidebar-trigger]]:scale-90',
        'data-docked:[&>[data-slot=sidebar-trigger]]:[transition:opacity_80ms_var(--ease-out),scale_80ms_var(--ease-out),visibility_0s_80ms]',
        'motion-reduce:transition-none',
        'motion-reduce:[&>[data-slot=sidebar-trigger]]:transition-none!'
      ])
    )
  })

  test('groups history buttons 4px apart in tertiary ink, starts the title 2px later and 4px in, and spaces actions 12px', () => {
    const html = renderToStaticMarkup(bar())
    const history = tagWith(html, 'data-slot="top-bar-history"')
    expect(attributeOf(history, 'role')).toBe('group')
    expect(attributeOf(history, 'aria-label')).toBe('History')
    expect(classesOf(history)).toEqual(expect.arrayContaining(['gap-1', 'me-0.5', '*:text-fg-tertiary']))
    expect(classesOf(tagWith(html, 'data-slot="top-bar-title"'))).toEqual(
      expect.arrayContaining(['min-w-0', 'flex-1', 'ps-1'])
    )
    expect(classesOf(tagWith(html, 'data-slot="top-bar-actions"'))).toEqual(
      expect.arrayContaining(['ms-auto', 'gap-3'])
    )
  })
})
