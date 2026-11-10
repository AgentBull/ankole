import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Tabs, TabsList, TabsTrigger } from '../src/components/tabs'

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
