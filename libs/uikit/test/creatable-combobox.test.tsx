import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  CreatableCombobox,
  filterCreatableComboboxOptions,
  hasHighlightedComboboxOption,
  resolveCreatableComboboxBlur
} from '../src/components/creatable-combobox'

describe('CreatableCombobox', () => {
  test('renders an empty value as no selection', () => {
    const html = renderToStaticMarkup(
      <CreatableCombobox
        value={null}
        options={[{ value: 'gpt-5.6-sol', label: 'GPT-5.6-Sol' }]}
        placeholder="Select a model"
        onValueChange={() => {}}
      />
    )

    expect(html).toContain('placeholder="Select a model"')
    expect(comboboxInputValue(html)).toBe('')
    expect(html).not.toContain('data-slot="combobox-clear"')
    expect(html).not.toContain('>null<')
  })

  test('shows a known option label without exposing its stored value first', () => {
    const html = renderToStaticMarkup(
      <CreatableCombobox
        value="gpt-5.6-sol"
        options={[{ value: 'gpt-5.6-sol', label: 'GPT-5.6-Sol' }]}
        onValueChange={() => {}}
      />
    )

    expect(comboboxInputValue(html)).toBe('GPT-5.6-Sol')
    expect(html).toContain('aria-label="Clear selection"')
    expect(html).toContain('aria-label="Open options"')
  })

  test('keeps a selected custom value', () => {
    const html = renderToStaticMarkup(<CreatableCombobox value="custom-model" options={[]} onValueChange={() => {}} />)

    expect(comboboxInputValue(html)).toBe('custom-model')
    expect(html).toContain('data-slot="combobox-clear"')
  })

  test('treats the selected label as display text instead of an active filter', () => {
    const options = [
      { value: 'gpt-5.6-sol', label: 'GPT-5.6-Sol' },
      { value: 'gpt-5.5', label: 'GPT-5.5' }
    ]

    expect(filterCreatableComboboxOptions(options, 'GPT-5.6-Sol', options[0])).toEqual(options)
    expect(filterCreatableComboboxOptions(options, '5.5', options[0])).toEqual([options[1]])
  })

  test('detects when a popup option is highlighted so Enter does not intercept option selection', () => {
    const highlightedItem = {
      hasAttribute: (name: string) => name === 'data-highlighted',
      querySelector: () => null
    }
    const listboxWithHighlight = {
      hasAttribute: () => false,
      querySelector: (selector: string) => (selector === '[data-highlighted]' ? highlightedItem : null)
    }

    expect(
      hasHighlightedComboboxOption({
        getAttribute: name => (name === 'aria-activedescendant' ? 'opt-1' : null),
        ownerDocument: { getElementById: id => (id === 'opt-1' ? highlightedItem : null) }
      })
    ).toBe(true)

    expect(
      hasHighlightedComboboxOption({
        getAttribute: name => (name === 'aria-controls' ? 'listbox-1' : null),
        ownerDocument: { getElementById: id => (id === 'listbox-1' ? listboxWithHighlight : null) }
      })
    ).toBe(true)

    expect(
      hasHighlightedComboboxOption({
        getAttribute: () => null,
        ownerDocument: { getElementById: () => null }
      })
    ).toBe(false)
  })

  test('syncs cleared input on blur and restores display text cleanly', () => {
    const options = [{ value: 'gpt-5.6-sol', label: 'GPT-5.6-Sol' }]

    expect(
      resolveCreatableComboboxBlur({
        currentValue: 'gpt-5.6-sol',
        inputValue: '   ',
        options,
        selected: options[0]!
      })
    ).toEqual({ inputValue: 'GPT-5.6-Sol', nextValue: '' })

    expect(
      resolveCreatableComboboxBlur({
        currentValue: '',
        inputValue: '   ',
        options,
        selected: null
      })
    ).toEqual({ inputValue: '', nextValue: undefined })

    expect(
      resolveCreatableComboboxBlur({
        currentValue: 'gpt-5.6-sol',
        inputValue: '  gpt-5.6-sol  ',
        options,
        selected: options[0]!
      })
    ).toEqual({ inputValue: 'GPT-5.6-Sol', nextValue: undefined })
  })
})

function comboboxInputValue(html: string) {
  return html.match(/<input[^>]*role="combobox"[^>]*value="([^"]*)"/)?.[1]
}
