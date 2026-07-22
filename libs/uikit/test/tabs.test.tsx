import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '../src/components/tabs'

describe('Tabs', () => {
  test('marks horizontal tabs for a stacked list and panel layout', () => {
    const html = renderTabs()

    expect(html).toContain('data-orientation="horizontal"')
    expect(html).toContain('data-horizontal=""')
    expect(html).not.toContain('data-vertical=""')
  })

  test('forwards vertical orientation to the tabs primitive', () => {
    const html = renderTabs('vertical')

    expect(html).toContain('data-orientation="vertical"')
    expect(html).toContain('data-vertical=""')
    expect(html).not.toContain('data-horizontal=""')
    expect(html).toContain('aria-orientation="vertical"')
  })
})

function renderTabs(orientation: 'horizontal' | 'vertical' = 'horizontal') {
  return renderToStaticMarkup(
    <Tabs value="first" orientation={orientation}>
      <TabsList>
        <TabsTrigger value="first">First</TabsTrigger>
        <TabsTrigger value="second">Second</TabsTrigger>
      </TabsList>
      <TabsContent value="first">First panel</TabsContent>
      <TabsContent value="second">Second panel</TabsContent>
    </Tabs>
  )
}
