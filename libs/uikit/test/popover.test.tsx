import { describe, expect, test } from 'bun:test'
import { Popover as PopoverPrimitive } from '@base-ui/react/popover'
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
    const anchor = { current: null }
    const tree = PopoverContent({ anchor, children: 'Current title' })
    const positioner = [...elements(tree)].find(element => element.type === PopoverPrimitive.Positioner)
    expect(positioner?.props.anchor).toBe(anchor)
  })
})
