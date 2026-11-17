import { describe, expect, test } from 'bun:test'
import { PopoverContent as PopoverContentPrimitive } from '@ui-sdk/react/popover'
import { isValidElement, type ReactElement } from 'react'
import { PopoverContent } from '../src/components/popover'

type Element = ReactElement<{ children?: unknown; anchor?: unknown }>

/** The elements that a component returns, walked down through each element's `children`. */
function* elements(node: unknown): Generator<Element> {
  if (!isValidElement(node)) return
  const element = node as Element
  yield element
  const children = element.props.children
  for (const child of Array.isArray(children) ? children : [children]) yield* elements(child)
}

describe('PopoverContent', () => {
  test('places a popover that opens without a trigger beside the anchor that the caller names', () => {
    const anchor = { x: 10, y: 20 }
    const tree = PopoverContent({ anchor, children: 'Current title' })
    const content = [...elements(tree)].find(element => element.type === PopoverContentPrimitive)
    expect(content?.props.anchor).toBe(anchor)
  })
})
