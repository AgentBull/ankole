import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '../src/components/select'

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

  test('preserves custom value formatting', () => {
    const html = renderToStaticMarkup(
      <Select value="openrouter">
        <SelectTrigger>
          <SelectValue>{value => `Custom ${String(value)}`}</SelectValue>
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="openrouter">OpenRouter</SelectItem>
        </SelectContent>
      </Select>
    )

    expect(html).toContain('Custom openrouter')
    expect(html).not.toContain('>OpenRouter<')
  })
})
