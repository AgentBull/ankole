import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Button } from '../src/components/button'

describe('Button', () => {
  test('keeps an incomplete action clickable while giving it a muted appearance', () => {
    const html = renderToStaticMarkup(<Button incomplete>Save</Button>)

    expect(html).toContain('data-incomplete="true"')
    expect(html).toContain('bg-muted')
    expect(html).toContain('text-muted-foreground')
    expect(html).not.toContain('disabled=""')
    expect(html).not.toContain('aria-disabled')
  })
})
