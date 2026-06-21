import { describe, expect, it } from 'bun:test'
import { createTodoTool, TodoStore } from './todo-tool'

describe('TodoStore', () => {
  // Walks the tricky paths together: a replace write, then a merge that patches
  // some ids / invents others / carries an invalid status (which must default to
  // pending, not be dropped), then a replace whose payload has a duplicate id
  // (last one wins). The final assertions check the active-only snapshot hides
  // completed/cancelled items.
  it('normalizes replacement and merge writes while keeping the active todo snapshot useful', () => {
    const store = new TodoStore()
    expect(store.read()).toEqual([])

    const todos = store.write([
      { id: '1', content: 'Plan', status: 'in_progress' },
      { id: '2', content: 'Ship', status: 'pending' },
      { id: '3', content: 'Done', status: 'completed' }
    ])

    expect(todos).toEqual([
      { id: '1', content: 'Plan', status: 'in_progress' },
      { id: '2', content: 'Ship', status: 'pending' },
      { id: '3', content: 'Done', status: 'completed' }
    ])
    expect(store.snapshot().summary).toEqual({
      total: 3,
      pending: 1,
      in_progress: 1,
      completed: 1,
      cancelled: 0
    })

    store.write(
      [
        { id: '1', status: 'completed' },
        { id: '3', content: 'Verify', status: 'invalid' },
        { id: '4', content: 'New invalid status', status: 'invalid' }
      ],
      true
    )

    expect(store.read()).toEqual([
      { id: '1', content: 'Plan', status: 'completed' },
      { id: '2', content: 'Ship', status: 'pending' },
      { id: '3', content: 'Verify', status: 'completed' },
      { id: '4', content: 'New invalid status', status: 'pending' }
    ])

    store.write([
      { id: '1', content: 'Old', status: 'pending' },
      { id: '1', content: 'New', status: 'in_progress' },
      { id: '2', content: 'Done', status: 'completed' },
      { id: '3', content: 'Cancelled', status: 'cancelled' }
    ])

    expect(store.read()).toEqual([
      { id: '1', content: 'New', status: 'in_progress' },
      { id: '2', content: 'Done', status: 'completed' },
      { id: '3', content: 'Cancelled', status: 'cancelled' }
    ])
    expect(store.formatActiveSnapshot()).toContain('[>] 1. New (in_progress)')
    expect(store.formatActiveSnapshot()).not.toContain('Done')
    expect(store.formatActiveSnapshot()).not.toContain('Cancelled')
  })

  // Guards the context-window caps: 300 items truncate to 256, and an oversized
  // content string is cut to 4000 chars with the visible truncation marker.
  it('caps item count and item content length', () => {
    const store = new TodoStore()
    store.write(
      Array.from({ length: 300 }, (_, index) => ({
        id: String(index),
        content: index === 0 ? 'x'.repeat(5000) : `item ${index}`,
        status: 'pending'
      }))
    )

    expect(store.read()).toHaveLength(256)
    expect(store.read()[0]!.content).toHaveLength(4000)
    expect(store.read()[0]!.content.endsWith(' [truncated]')).toBe(true)
  })
})

describe('createTodoTool', () => {
  it('reads, replaces, merges, and returns the full current list', async () => {
    const store = new TodoStore()
    const tool = createTodoTool(store)

    const empty = await tool.execute('call-read', {})
    expect(empty.details.summary.total).toBe(0)

    const replaced = await tool.execute('call-replace', {
      todos: [{ id: '1', content: 'Plan', status: 'pending' }]
    })
    expect(replaced.details.todos).toEqual([{ id: '1', content: 'Plan', status: 'pending' }])

    const merged = await tool.execute('call-merge', {
      merge: true,
      todos: [
        { id: '1', content: 'Plan', status: 'completed' },
        { id: '2', content: 'Verify', status: 'pending' }
      ]
    })
    expect(merged.details.todos).toEqual([
      { id: '1', content: 'Plan', status: 'completed' },
      { id: '2', content: 'Verify', status: 'pending' }
    ])
    expect(JSON.parse(merged.content[0]!.type === 'text' ? merged.content[0]!.text : '{}').summary.total).toBe(2)
  })
})
