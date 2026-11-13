import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '../src/components/select'
import { CaretDownFilled } from '../src/icons'
import { attributeOf, classesOf, pathOf, tagWith } from './markup'

describe('Select', () => {
  test('shows the selected item label instead of its raw value', () => {
    const html = renderToStaticMarkup(
      <Select value="openrouter">
        <SelectTrigger>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="openai">OpenAI</SelectItem>
          <SelectItem value="openrouter">OpenRouter</SelectItem>
        </SelectContent>
      </Select>
    )

    expect(html).toContain('OpenRouter')
    expect(html).not.toContain('>openrouter<')
  })

  test('waits for loading options instead of showing a raw value', () => {
    const loading = renderToStaticMarkup(
      <Select value="01a1d381-tenant" loading>
        <SelectTrigger>
          <SelectValue placeholder="Choose tenant" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="__all__">All tenants</SelectItem>
        </SelectContent>
      </Select>
    )
    // The hidden form input still carries the value; only the visible value waits.
    const visible = loading.slice(loading.indexOf('data-slot="select-value"'), loading.indexOf('<svg'))
    expect(visible).toContain('data-slot="skeleton"')
    expect(visible).not.toContain('01a1d381-tenant')

    const known = renderToStaticMarkup(
      <Select value="openrouter" loading>
        <SelectTrigger>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="openrouter">OpenRouter</SelectItem>
        </SelectContent>
      </Select>
    )
    expect(known).toContain('OpenRouter')
    expect(known).not.toContain('data-slot="skeleton"')

    const loaded = renderToStaticMarkup(
      <Select value="retired-provider">
        <SelectTrigger>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="openrouter">OpenRouter</SelectItem>
        </SelectContent>
      </Select>
    )
    expect(loaded).toContain('retired-provider')
  })

  test('preserves an explicit items mapping', () => {
    const html = renderToStaticMarkup(
      <Select value="openrouter" items={{ openrouter: 'Explicit OpenRouter label' }}>
        <SelectTrigger>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="openrouter">Inferred label</SelectItem>
        </SelectContent>
      </Select>
    )

    expect(html).toContain('Explicit OpenRouter label')
    expect(html).not.toContain('>Inferred label<')
  })

  test('draws a toolbar selector as a 36px label with a 12px filled arrow and a content-box wash', () => {
    const html = renderToStaticMarkup(
      <Select value="members">
        <SelectTrigger size="toolbar" variant="ghost" aria-label="Recipient">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="members">Members</SelectItem>
        </SelectContent>
      </Select>
    )
    const trigger = tagWith(html, 'aria-label="Recipient"')
    expect(attributeOf(trigger, 'data-size')).toBe('toolbar')
    expect(classesOf(trigger)).toEqual(
      expect.arrayContaining([
        'data-[size=toolbar]:h-9',
        'data-[size=toolbar]:p-1.75',
        'data-[size=toolbar]:text-50',
        'data-[size=toolbar]:bg-clip-content',
        'hover:bg-accent'
      ])
    )
    // The toolbar arrow is Fluent's filled caret, not the outline chevron of a field select.
    expect(html).toContain(pathOf(<CaretDownFilled />))
    expect(html).not.toContain('size-3.5')
  })

  test('lets a toolbar selector give up its label to an ellipsis but never its arrow', () => {
    const trigger = classesOf(
      tagWith(
        renderToStaticMarkup(
          <Select value="members">
            <SelectTrigger size="toolbar" variant="ghost" aria-label="Recipient">
              <SelectValue />
            </SelectTrigger>
          </Select>
        ),
        'aria-label="Recipient"'
      )
    )
    // The 32px floor is the 7px padding and 1px edge on each side, the 12px arrow, and the 4px gap before it.
    expect(trigger).toEqual(
      expect.arrayContaining([
        'min-w-0',
        'data-[size=toolbar]:min-w-8',
        'data-[size=toolbar]:*:data-[slot=select-value]:block',
        'data-[size=toolbar]:*:data-[slot=select-value]:truncate'
      ])
    )
  })
})
