import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Tabs, TabsLabel, TabsList, TabsTrigger } from '../src/components/tabs'
import { classesOf, tagWith } from './markup'

test('draws chip tabs as a 24px icon with a label that opens only on the current tab', () => {
  const html = renderToStaticMarkup(
    <Tabs value="home">
      <TabsList variant="chip" aria-label="Sections">
        <TabsTrigger value="home" aria-label="Home">
          <svg data-testid="home-icon" />
          <TabsLabel aria-hidden>Home</TabsLabel>
        </TabsTrigger>
        <TabsTrigger value="chat" aria-label="Chat">
          <svg />
          <TabsLabel aria-hidden>Chat</TabsLabel>
        </TabsTrigger>
      </TabsList>
    </Tabs>
  )

  const list = tagWith(html, 'data-variant="chip"')
  expect(classesOf(list)).toContain('gap-2')
  // The current tab sits on the selected fill, which the chip list draws with the object tabs' travelling indicator.
  expect(html).toContain('selected-surface')
  const trigger = classesOf(tagWith(html, 'aria-label="Home"'))
  expect(trigger).toContain('group/tabs-trigger')
  expect(trigger).toContain('group-data-[variant=chip]/tabs-list:px-1')
  expect(trigger).toContain('group-data-[variant=chip]/tabs-list:py-0.5')
  expect(trigger).toContain('group-data-[variant=chip]/tabs-list:text-85')
  expect(trigger).toContain("group-data-[variant=chip]/tabs-list:[&_svg:not([class*='size-'])]:size-6")
  // A closed tab draws in the secondary colour; the open tab draws its icon and Medium label in the primary colour.
  expect(trigger).toContain('group-data-[variant=chip]/tabs-list:text-fg-secondary')
  expect(trigger).toContain('group-data-[variant=chip]/tabs-list:data-active:text-foreground')
  expect(trigger).toContain('group-data-[variant=chip]/tabs-list:data-active:font-medium')
  expect(trigger).not.toContain('group-data-[variant=chip]/tabs-list:data-active:text-fg-secondary')
  // A label column is closed by default and opens with its tab's active state.
  const labels = [...html.matchAll(/<span[^>]*data-slot="tabs-label"[^>]*>/g)].map(match => classesOf(match[0]))
  expect(labels).toHaveLength(2)
  for (const label of labels) {
    expect(label).toContain('grid-cols-[minmax(0,0fr)]')
    expect(label).toContain('group-data-active/tabs-trigger:grid-cols-[minmax(0,1fr)]')
  }
})

test('announces the orientation of vertical tabs', () => {
  const html = renderToStaticMarkup(
    <Tabs value="first" orientation="vertical">
      <TabsList>
        <TabsTrigger value="first">First</TabsTrigger>
        <TabsTrigger value="second">Second</TabsTrigger>
      </TabsList>
    </Tabs>
  )

  const tablist = html.match(/<[^>]*\brole="tablist"[^>]*>/)?.[0]
  expect(tablist).toContain('aria-orientation="vertical"')
})
