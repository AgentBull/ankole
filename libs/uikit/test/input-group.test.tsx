import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  InputGroup,
  InputGroupActions,
  InputGroupAddon,
  InputGroupButton,
  InputGroupSend,
  InputGroupStop,
  InputGroupText,
  InputGroupTextarea
} from '../src/components/input-group'
import { attributeOf, classesOf, tagWith } from './markup'

function composer(ready: boolean) {
  return renderToStaticMarkup(
    <InputGroup variant="composer">
      <InputGroupTextarea aria-label="Message" placeholder="Ask anything" />
      <InputGroupAddon align="block-end">
        <InputGroupButton size="icon-lg" aria-label="Attach">
          <svg aria-hidden />
        </InputGroupButton>
        <InputGroupButton size="toolbar">Members</InputGroupButton>
        <InputGroupSend ready={ready} aria-label="Send">
          <svg aria-hidden />
        </InputGroupSend>
      </InputGroupAddon>
    </InputGroup>
  )
}

describe('InputGroup composer', () => {
  test('floats on the composer surface instead of a form slot', () => {
    const group = tagWith(composer(false), 'data-slot="input-group"')
    expect(attributeOf(group, 'data-variant')).toBe('composer')
    const classes = classesOf(group)
    // The composer is positioned, so the ring of `composer-surface` covers its own border.
    expect(classes).toEqual(
      expect.arrayContaining(['relative', 'composer-surface', 'flex-col', 'items-stretch', 'px-0'])
    )
    expect(classes.some(name => ['bg-field', 'rounded-control', 'border-field-edge'].includes(name))).toBe(false)
  })

  test('draws its edge as a masked ring, in the quaternary gradient on light and the hairline on dark', async () => {
    const styles = (await Bun.file(new URL('../src/styles.css', import.meta.url)).text()).replace(/\s+/g, ' ')
    const utility = (name: string) => {
      const start = styles.indexOf(`@utility ${name} {`)
      return styles.slice(start, styles.indexOf('@utility', start + 1))
    }
    // A gradient cannot be a border colour, so the ring lies over the composer's transparent border.
    const surface = utility('composer-surface')
    expect(surface).toContain('border: 1px solid transparent;')
    expect(surface).toContain(
      'inset: -1px; padding: 1px; border-radius: inherit; background: linear-gradient(var(--composer-edge-angle), var(--composer-edge-stops));'
    )
    expect(surface).toContain('mask: linear-gradient(#000 0 0) content-box exclude, linear-gradient(#000 0 0);')
    // A list that opens from the composer keeps the overlay hairline and draws no ring.
    const menu = utility('composer-menu')
    expect(menu).toContain('border: 1px solid var(--ceramic-hairline);')
    expect(menu).not.toContain('--composer-edge')
    // The edge turns once every 8 seconds while the text field holds focus, rests where it stopped, and keeps still
    // for a person who asks for less motion.
    expect(styles).toContain(
      "@property --composer-edge-angle { syntax: '<angle>'; inherits: false; initial-value: 90deg; }"
    )
    expect(styles).toContain('@keyframes composer-edge-turn { to { --composer-edge-angle: 450deg; } }')
    expect(surface).toContain('animation: composer-edge-turn 8s linear infinite paused;')
    expect(surface).toContain('&:has(:is(textarea, input):focus)::before { animation-play-state: running; }')
    expect(surface).toContain('@media (prefers-reduced-motion: reduce) { &::before { animation: none; } }')

    const theme = (await Bun.file(new URL('../src/theme.css', import.meta.url)).text()).replace(/\s+/g, ' ')
    const dark = theme.indexOf("[data-theme='dark'] {")
    expect(theme.slice(0, dark)).toContain(
      '--border-quaternary-stops: #6ecbf9 0%, #7bb3ed 43%, var(--color-brand-60) 100%;'
    )
    expect(theme.slice(0, dark)).toContain(
      '--border-quaternary: linear-gradient(90deg, var(--border-quaternary-stops));'
    )
    expect(theme.slice(0, dark)).toContain('--composer-edge-stops: var(--border-quaternary-stops);')
    expect(theme.slice(dark)).toContain('--composer-edge-stops: var(--ceramic-hairline), var(--ceramic-hairline);')
  })

  test('sets 16/24 text inset 16px and 22px with a primary caret and a disabled-colour placeholder', () => {
    const textarea = classesOf(tagWith(composer(false), 'data-slot="input-group-control"'))
    expect(textarea).toEqual(
      expect.arrayContaining([
        'group-data-[variant=composer]/input-group:text-100',
        // The base text area sets its own leading, which a type step alone does not replace.
        'group-data-[variant=composer]/input-group:leading-6',
        'group-data-[variant=composer]/input-group:pt-4',
        'group-data-[variant=composer]/input-group:px-5.5',
        'group-data-[variant=composer]/input-group:caret-primary',
        'group-data-[variant=composer]/input-group:placeholder:text-fg-disabled'
      ])
    )
  })

  test('lays the tools along a 36px toolbar 10px from the edges, with 36px buttons that tint their icon box', () => {
    const html = composer(false)
    expect(classesOf(tagWith(html, 'data-slot="input-group-addon"'))).toEqual(
      expect.arrayContaining([
        'group-data-[variant=composer]/input-group:h-9',
        'group-data-[variant=composer]/input-group:px-2.5',
        'group-data-[variant=composer]/input-group:gap-0'
      ])
    )
    const attach = classesOf(tagWith(html, 'aria-label="Attach"'))
    expect(attach).toEqual(expect.arrayContaining(['size-9', 'p-1.75', 'bg-clip-content']))
    expect(attach).not.toContain('rounded-mini')
    const selector = classesOf(tagWith(html, 'data-size="toolbar"'))
    expect(selector).toEqual(expect.arrayContaining(['h-9', 'text-50', 'font-normal']))
  })

  test('keeps an empty send pill in the slot fill and turns it primary once the draft is ready', () => {
    const empty = tagWith(composer(false), 'data-slot="input-group-send"')
    expect(attributeOf(empty, 'type')).toBe('submit')
    expect(attributeOf(empty, 'data-ready')).toBeUndefined()
    expect(classesOf(empty)).toEqual(
      expect.arrayContaining(['h-5', 'min-w-13', 'px-4', 'rounded-surface', 'bg-field-hover', 'text-fg-disabled'])
    )

    const ready = tagWith(composer(true), 'data-slot="input-group-send"')
    expect(attributeOf(ready, 'data-ready')).toBe('true')
    expect(classesOf(ready)).toEqual(
      expect.arrayContaining(['data-ready:bg-primary', 'data-ready:text-primary-foreground'])
    )
  })

  test('draws the stop button as the same pill with a secondary icon that never submits the draft', () => {
    const stop = tagWith(
      renderToStaticMarkup(
        <InputGroupStop aria-label="Stop">
          <svg aria-hidden />
        </InputGroupStop>
      ),
      'data-slot="input-group-stop"'
    )
    expect(attributeOf(stop, 'type')).toBe('button')
    const classes = classesOf(stop)
    expect(classes).toEqual(
      expect.arrayContaining(['h-5', 'min-w-13', 'px-4', 'rounded-surface', 'bg-field-hover', 'text-fg-secondary'])
    )
    expect(classes).toEqual(expect.arrayContaining(['hover:bg-layer-hover', 'hover:text-foreground']))
    expect(classes).not.toContain('text-fg-disabled')
  })

  test('groups the end of the toolbar so the group, not each pill, takes the free room', () => {
    const html = renderToStaticMarkup(
      <InputGroup variant="composer">
        <InputGroupAddon align="block-end">
          <InputGroupButton size="icon-lg" aria-label="Attach">
            <svg aria-hidden />
          </InputGroupButton>
          <InputGroupActions>
            <InputGroupStop aria-label="Stop">
              <svg aria-hidden />
            </InputGroupStop>
            <InputGroupSend aria-label="Send">
              <svg aria-hidden />
            </InputGroupSend>
          </InputGroupActions>
        </InputGroupAddon>
      </InputGroup>
    )
    expect(classesOf(tagWith(html, 'data-slot="input-group-actions"'))).toEqual(
      expect.arrayContaining(['ms-auto', 'flex', 'shrink-0', 'items-center', 'gap-2'])
    )
    for (const label of ['Stop', 'Send']) {
      const pill = classesOf(tagWith(html, `aria-label="${label}"`))
      // A pill takes no margin of its own, so two pills never split the free room between them.
      expect(pill).not.toContain('ms-auto')
      // The hit area spans the 36px toolbar but stays out of the 8px gap, so the pills' areas never overlap.
      expect(pill).toEqual(expect.arrayContaining(['after:absolute', 'after:-inset-y-2', 'after:inset-x-0']))
      expect(pill).not.toContain('after:-inset-2')
    }
  })

  test('lets pills placed straight in the toolbar share one end: the first pill takes the free room', () => {
    const html = renderToStaticMarkup(
      <InputGroup variant="composer">
        <InputGroupAddon align="block-end">
          <InputGroupStop aria-label="Stop">
            <svg aria-hidden />
          </InputGroupStop>
          <InputGroupSend aria-label="Send">
            <svg aria-hidden />
          </InputGroupSend>
        </InputGroupAddon>
      </InputGroup>
    )
    const stop = classesOf(tagWith(html, 'aria-label="Stop"'))
    const send = classesOf(tagWith(html, 'aria-label="Send"'))
    expect(stop).toContain('[[data-slot=input-group-addon]>&]:ms-auto')
    expect(send).toEqual(
      expect.arrayContaining([
        '[[data-slot=input-group-addon]>&]:ms-auto',
        '[[data-slot=input-group-addon]>[data-slot=input-group-stop]+&]:ms-0'
      ])
    )
  })

  test('sets a toolbar label in 12px secondary text inset like a toolbar button label', () => {
    const label = classesOf(
      tagWith(
        renderToStaticMarkup(
          <InputGroup variant="composer">
            <InputGroupAddon align="block-end">
              <InputGroupText data-label>Assistant</InputGroupText>
            </InputGroupAddon>
          </InputGroup>
        ),
        'data-label'
      )
    )
    expect(label).toEqual(
      expect.arrayContaining([
        'group-data-[variant=composer]/input-group:text-50',
        'group-data-[variant=composer]/input-group:px-2',
        'group-data-[variant=composer]/input-group:text-fg-secondary'
      ])
    )
  })
})
