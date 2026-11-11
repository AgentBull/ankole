import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Button, buttonVariants } from '../src/components/button'
import { classesOf, tagWith } from './markup'

function buttonClasses(node: React.ReactNode) {
  return classesOf(tagWith(renderToStaticMarkup(node), 'data-slot="button"'))
}

describe('Button toolbar sizes', () => {
  test('holds a 20px icon in a 36px icon button whose ghost hover tints only the icon box', () => {
    const classes = buttonClasses(
      <Button variant="ghost" size="icon-lg" aria-label="Search">
        <svg aria-hidden />
      </Button>
    )
    expect(classes).toEqual(
      expect.arrayContaining([
        'size-9',
        'p-1.75',
        "[&_svg:not([class*='size-'])]:size-5",
        'bg-clip-content',
        'rounded-[calc(var(--radius-micro)+var(--spacing)*2)]',
        'hover:bg-accent',
        'active:bg-layer-pressed'
      ])
    )
    expect(classes).not.toContain('bg-clip-padding')
    expect(classes).not.toContain('rounded-control')
  })

  test('holds a 20px icon 6px inside a 32px action-row button whose ghost hover tints only the icon box', () => {
    const classes = buttonClasses(
      <Button variant="ghost" size="icon-md" aria-label="Copy">
        <svg aria-hidden />
      </Button>
    )
    expect(classes).toEqual(
      expect.arrayContaining([
        'size-8',
        'p-1.25',
        "[&_svg:not([class*='size-'])]:size-5",
        'bg-clip-content',
        'rounded-[calc(var(--radius-micro)+var(--spacing)*1.5)]',
        'hover:bg-accent'
      ])
    )
    expect(classes).not.toContain('rounded-control')
  })

  test('keeps the full fill of a solid or outline button at the same size', () => {
    const classes = buttonClasses(
      <Button variant="outline" size="icon-lg" aria-label="Share">
        <svg aria-hidden />
      </Button>
    )
    expect(classes).toEqual(expect.arrayContaining(['size-9', 'bg-clip-padding', 'rounded-control']))
    expect(classes).not.toContain('bg-clip-content')
  })

  test('sets a toolbar label in 12/20 regular text', () => {
    const classes = buttonClasses(
      <Button variant="ghost" size="toolbar">
        Members
      </Button>
    )
    expect(classes).toEqual(expect.arrayContaining(['h-9', 'text-50', 'font-normal', 'bg-clip-content']))
    expect(classes).not.toContain('text-[13px]')
    expect(classes).not.toContain('font-medium')
  })

  test('sets a 24px button label in the 12/20 step', () => {
    const classes = buttonClasses(
      <Button variant="ghost" size="xs">
        Source
      </Button>
    )
    expect(classes).toEqual(expect.arrayContaining(['h-6', 'text-50']))
    for (const replaced of ['text-xs', 'text-[13px]', 'leading-none']) expect(classes).not.toContain(replaced)
  })
})

describe('buttonVariants', () => {
  const classes = (props: Parameters<typeof buttonVariants>[0]) => buttonVariants(props).split(/\s+/)

  test('gives an element styled as a ghost icon button the same content-box fill as the Button itself', () => {
    const raw = classes({ variant: 'ghost', size: 'icon-lg', className: 'max-md:hidden' })
    expect(raw).toEqual(
      expect.arrayContaining([
        'bg-clip-content',
        'rounded-[calc(var(--radius-micro)+var(--spacing)*2)]',
        'max-md:hidden'
      ])
    )
    expect(raw).not.toContain('bg-clip-padding')
    expect(raw).not.toContain('rounded-control')
    expect(raw.sort()).toEqual(
      buttonClasses(
        <Button variant="ghost" size="icon-lg" className="max-md:hidden" aria-label="Pod">
          <svg aria-hidden />
        </Button>
      )
        .filter(name => name !== 'motion-safe:button-press')
        .sort()
    )
  })

  test('drops the base label size, weight, gap, and leading under the toolbar size', () => {
    const raw = classes({ variant: 'ghost', size: 'toolbar' })
    expect(raw).toEqual(expect.arrayContaining(['h-9', 'gap-1', 'text-50', 'font-normal', 'bg-clip-content']))
    for (const replaced of [
      'text-[13px]',
      'font-medium',
      'gap-2',
      'leading-none',
      'bg-clip-padding',
      'rounded-control'
    ]) {
      expect(raw).not.toContain(replaced)
    }
  })
})

describe('Button', () => {
  test('keeps an incomplete action clickable while giving it a muted appearance', () => {
    const html = renderToStaticMarkup(<Button incomplete>Save</Button>)

    expect(html).toContain('data-incomplete="true"')
    expect(html).not.toContain('disabled=""')
    expect(html).not.toContain('aria-disabled')
  })
})
