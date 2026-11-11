import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  Board,
  BoardCard,
  BoardCardActions,
  BoardCardAside,
  BoardCardFooter,
  BoardCardHeader,
  BoardCardTitle,
  BoardColumn,
  BoardColumnHeader,
  BoardPresence
} from '../src/components/board'
import { attributeOf, classesOf, tagWith } from './markup'

function board({ selected = false, dropTarget = false } = {}) {
  return renderToStaticMarkup(
    <Board>
      <BoardColumn dropTarget={dropTarget} aria-label="In progress">
        <BoardColumnHeader icon={<svg data-icon="half" />} tone="blue" count={2} actions={<button type="button" />}>
          In progress
        </BoardColumnHeader>
        <BoardCard selected={selected}>
          <BoardCardHeader>
            Background work
            <BoardCardAside>Running</BoardCardAside>
          </BoardCardHeader>
          <BoardCardTitle render={<button type="button" />}>Build the report</BoardCardTitle>
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
  test('lays its columns out in a wrapping grid, so a board never scrolls sideways', () => {
    const classes = classesOf(tagWith(board(), 'data-slot="board"'))
    expect(classes).toContain('grid')
    expect(classes).toContain('grid-cols-[repeat(auto-fit,minmax(min(10.5rem,100%),1fr))]')
  })

  test('draws a column as a quiet surface that its label names', () => {
    const column = tagWith(board(), 'data-slot="board-column"')
    expect(column).toContain('aria-label="In progress"')
    expect(classesOf(column)).toContain('bg-background-secondary')
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

  test('marks a column that a dragged card may land in, and the card whose details are open', () => {
    expect(attributeOf(tagWith(board(), 'data-slot="board-column"'), 'data-drop-target')).toBeUndefined()
    expect(attributeOf(tagWith(board({ dropTarget: true }), 'data-slot="board-column"'), 'data-drop-target')).toBe(
      'true'
    )
    expect(attributeOf(tagWith(board(), 'data-slot="board-card"'), 'data-selected')).toBeUndefined()
    expect(attributeOf(tagWith(board({ selected: true }), 'data-slot="board-card"'), 'data-selected')).toBe('true')
  })

  test('renders the title as the element that the caller passes, such as a button', () => {
    const title = tagWith(board(), 'data-slot="board-card-title"')
    expect(title.startsWith('<button')).toBe(true)
    expect(classesOf(title)).toContain('line-clamp-2')
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
