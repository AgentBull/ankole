import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Button } from '../src/components/button'

describe('Button', () => {
  test('keeps an incomplete action clickable while giving it a muted appearance', () => {
    const html = renderToStaticMarkup(<Button incomplete>Save</Button>)

    expect(html).toContain('data-incomplete="true"')
    expect(html).not.toContain('disabled=""')
    expect(html).not.toContain('aria-disabled')
  })

  test('renders primary actions with ink primary tokens separate from brand and destructive colors', () => {
    const html = renderToStaticMarkup(<Button>Continue</Button>)

    expect(html).toContain('bg-primary')
    expect(html).toContain('border-b-primary-edge')
    expect(html).toContain('hover:bg-primary-hover')
    expect(html).not.toContain('brand-')
    expect(html).not.toContain('red-')
  })
})
