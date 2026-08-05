import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Input } from '../src/components/input'
import { InputGroup, InputGroupInput } from '../src/components/input-group'
import { Textarea } from '../src/components/textarea'

describe('Input', () => {
  test('uses an explicit line height and balanced vertical padding for entered text', () => {
    const html = renderToStaticMarkup(<Input type="search" />)

    expect(html).toContain('text-sm leading-5')
    expect(html).toContain('py-2')
  })

  test('hides the browser search decorations when the product owns the clear action', () => {
    const searchHTML = renderToStaticMarkup(<Input type="search" />)
    const textHTML = renderToStaticMarkup(<Input type="text" />)

    expect(searchHTML).toContain('webkit-search-cancel-button')
    expect(searchHTML).toContain('webkit-search-decoration')
    expect(textHTML).not.toContain('webkit-search-cancel-button')
  })

  test('uses a file-specific layout without changing ordinary text inputs', () => {
    const html = renderToStaticMarkup(<Input type="file" />)

    expect(html).toContain('cursor-pointer py-1')
    expect(html).not.toContain('cursor-pointer py-1 py-2')
  })

  test('keeps grouped inputs and textareas on the same stable text baseline', () => {
    const groupHTML = renderToStaticMarkup(
      <InputGroup>
        <InputGroupInput />
      </InputGroup>
    )
    const textareaHTML = renderToStaticMarkup(<Textarea />)

    expect(groupHTML).toContain('text-sm leading-5')
    expect(groupHTML).toContain('py-2')
    expect(groupHTML).not.toContain('transition-[background-color,border-color]')
    expect(textareaHTML).toContain('py-3 text-sm leading-5')
    expect(textareaHTML).not.toContain('transition-[background-color,border-color]')
  })

  test('shows native invalid state on standalone and grouped fields', () => {
    const inputHTML = renderToStaticMarkup(<Input required />)
    const groupHTML = renderToStaticMarkup(
      <InputGroup>
        <InputGroupInput required />
      </InputGroup>
    )
    const textareaHTML = renderToStaticMarkup(<Textarea required />)

    expect(inputHTML).toContain('user-invalid:border-b-destructive')
    expect(groupHTML).toContain('has-[:user-invalid]:border-b-destructive')
    expect(textareaHTML).toContain('user-invalid:border-b-destructive')
  })

  test('removes the active underline from disabled text controls', () => {
    const inputHTML = renderToStaticMarkup(<Input disabled />)
    const groupHTML = renderToStaticMarkup(
      <InputGroup>
        <InputGroupInput disabled />
      </InputGroup>
    )
    const textareaHTML = renderToStaticMarkup(<Textarea disabled />)

    expect(inputHTML).toContain('disabled:border-b-transparent')
    expect(inputHTML).toContain('disabled:text-fg-disabled')
    expect(groupHTML).toContain('has-[input:disabled]:border-b-transparent')
    expect(textareaHTML).toContain('disabled:border-b-transparent')
  })
})
