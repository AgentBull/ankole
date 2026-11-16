import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  Board,
  BoardCard,
  BoardCardActions,
  BoardCardAside,
  BoardCardDescription,
  BoardCardFooter,
  BoardCardHeader,
  BoardCardProgress,
  BoardCardTitle,
  BoardColumn,
  BoardColumnEmpty,
  BoardColumnHeader,
  BoardPresence,
  type BoardCardTone
} from '../src/components/board'
import { attributeOf, classesOf, tagWith } from './markup'

function board({
  selected = false,
  dropTarget = false,
  tone = 'default'
}: {
  selected?: boolean
  dropTarget?: boolean
  tone?: BoardCardTone
} = {}) {
  return renderToStaticMarkup(
    <Board>
      <BoardColumn dropTarget={dropTarget} aria-label="In progress">
        <BoardColumnHeader icon={<svg data-icon="half" />} tone="blue" count={2} actions={<button type="button" />}>
          In progress
        </BoardColumnHeader>
        <BoardCard selected={selected} tone={tone}>
          <BoardCardHeader>
            Background work
            <BoardCardAside>Running</BoardCardAside>
          </BoardCardHeader>
          <BoardCardTitle render={<button type="button" />}>Build the report</BoardCardTitle>
          <BoardCardDescription>Synthesizing metrics across 4 repositories.</BoardCardDescription>
          <BoardCardProgress value={2} max={4} label="2/4" />
          <BoardCardFooter>
            Research Agent
            <BoardCardAside>3m ago</BoardCardAside>
          </BoardCardFooter>
        </BoardCard>
      </BoardColumn>
    </Board>
  )
}

describe('Board', () => {
  test('lays its columns out in a wrapping equal-height grid, so a board never scrolls sideways', () => {
    const classes = classesOf(tagWith(board(), 'data-slot="board"'))
    expect(classes).toContain('grid')
    expect(classes).toContain('grid-cols-[repeat(auto-fit,minmax(min(15.5rem,100%),1fr))]')
    expect(classes).toContain('items-stretch')
  })

  test('draws a column as a quiet surface that its label names, and supports an empty lane placeholder', () => {
    const column = tagWith(board(), 'data-slot="board-column"')
    expect(column).toContain('aria-label="In progress"')
    expect(classesOf(column)).toContain('bg-layer-01')

    const empty = renderToStaticMarkup(<BoardColumnEmpty>Nothing queued</BoardColumnEmpty>)
    expect(tagWith(empty, 'data-slot="board-column-empty"')).toBeDefined()
    expect(empty).toContain('Nothing queued')
  })

  test('heads a column with its status icon in its tone, its title, its count, and its actions', () => {
    const html = board()
    const header = tagWith(html, 'data-slot="board-column-header"')
    expect(attributeOf(header, 'style')).toBe('--board-tone:var(--color-blue-50)')
    const icon = html.indexOf('data-icon="half"')
    const title = html.indexOf('In progress</span>')
    const count = html.indexOf('>2</span>')
    expect(icon).toBeGreaterThan(-1)
    expect(title).toBeGreaterThan(icon)
    expect(count).toBeGreaterThan(title)
    expect(html.indexOf('<button type="button"></button>')).toBeGreaterThan(count)
  })

  test('marks a column drop target, card selection, and attention tones without layout shifts', () => {
    expect(attributeOf(tagWith(board(), 'data-slot="board-column"'), 'data-drop-target')).toBeUndefined()
    expect(attributeOf(tagWith(board({ dropTarget: true }), 'data-slot="board-column"'), 'data-drop-target')).toBe(
      'true'
    )
    expect(attributeOf(tagWith(board(), 'data-slot="board-card"'), 'data-selected')).toBeUndefined()
    expect(attributeOf(tagWith(board({ selected: true }), 'data-slot="board-card"'), 'data-selected')).toBe('true')
    expect(attributeOf(tagWith(board(), 'data-slot="board-card"'), 'data-tone')).toBeUndefined()
    expect(attributeOf(tagWith(board({ tone: 'warning' }), 'data-slot="board-card"'), 'data-tone')).toBe('warning')
    expect(attributeOf(tagWith(board({ tone: 'danger' }), 'data-slot="board-card"'), 'data-tone')).toBe('danger')
  })

  test('stretches a button title across the whole card while elevating independent card controls', () => {
    const html = board()
    const cardClasses = classesOf(tagWith(html, 'data-slot="board-card"'))
    expect(cardClasses).toContain('relative')
    expect(cardClasses).toContain('[&_:is(a,button,input,select,textarea):not([data-slot=board-card-title])]:z-1')

    const title = tagWith(html, 'data-slot="board-card-title"')
    expect(title.startsWith('<button')).toBe(true)
    expect(classesOf(title)).toContain('line-clamp-2')
    expect(classesOf(title)).toContain('[:is(button,a)&]:after:inset-0')
  })

  test('renders card description and determinate progress row', () => {
    const html = board()
    expect(tagWith(html, 'data-slot="board-card-description"')).toBeDefined()
    expect(html).toContain('Synthesizing metrics across 4 repositories.')
    expect(tagWith(html, 'data-slot="board-card-progress"')).toBeDefined()
    expect(html).toContain('>2/4</span>')
  })

  test('pushes the trailing fact of a card row to its end', () => {
    const asides = [...board().matchAll(/<span[^>]*data-slot="board-card-aside"[^>]*>/g)].map(match => match[0])
    expect(asides).toHaveLength(2)
    for (const aside of asides) expect(classesOf(aside)).toContain('ms-auto')
  })

  test('keeps the actions of a card out of its row until the card is hovered or holds focus', () => {
    const actions = classesOf(
      tagWith(
        renderToStaticMarkup(
          <BoardCard>
            <BoardCardActions>
              <button type="button">Stop</button>
            </BoardCardActions>
          </BoardCard>
        ),
        'data-slot="board-card-actions"'
      )
    )
    expect(actions).toContain('hidden')
    expect(actions).toContain('group-hover/board-card:flex')
    expect(actions).toContain('group-focus-within/board-card:flex')
    expect(actions).toContain('[@media(hover:none)]:flex')
  })

  test('leads the presence pill with the avatars of the people at work', () => {
    const html = renderToStaticMarkup(<BoardPresence avatars={<i data-avatar="a" />}>2 agents working</BoardPresence>)
    expect(html.indexOf('data-avatar="a"')).toBeLessThan(html.indexOf('2 agents working'))
    expect(classesOf(tagWith(html, 'data-slot="board-presence"'))).toContain('rounded-full')
  })
})
