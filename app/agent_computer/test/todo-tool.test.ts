import { describe, expect, it } from 'bun:test'
import { createTodoTool, TodoStore } from '../src/tools/todo/todo-tool'

describe('todo reply presentation', () => {
  it('returns one full semantic plan snapshot after each write', async () => {
    const tool = createTodoTool(new TodoStore())
    expect(tool.describeActivity(tool.schema.parse({}))).toBeNull()

    const result = await tool.execute(
      'call-todo-1',
      tool.schema.parse({
        todos: [
          { id: 'inspect', content: 'Inspect current behavior', status: 'completed' },
          { id: 'repair', content: 'Repair the delivery path', status: 'in_progress' }
        ]
      })
    )

    expect(result.presentation).toEqual([
      {
        kind: 'plan.snapshot',
        payload: {
          operation_id: 'call-todo-1',
          items: [
            { id: 'inspect', content: 'Inspect current behavior', status: 'completed' },
            { id: 'repair', content: 'Repair the delivery path', status: 'in_progress' }
          ]
        }
      }
    ])
  })
})

describe('todo schema', () => {
  const tool = createTodoTool(new TodoStore())

  // The store trusts its input, so these rejections are the only thing standing
  // between a malformed write and the stored list.
  it('rejects an item the store would otherwise have to repair', () => {
    for (const todo of [
      { id: 'a', status: 'pending' },
      { id: '   ', content: 'Blank id', status: 'pending' },
      { id: 'a', content: '   ', status: 'pending' },
      { id: 'a', content: 'Unknown status', status: 'done' },
      { id: 'a', content: 'x'.repeat(4001), status: 'pending' },
      { id: 'a', content: 'Unknown field', status: 'pending', priority: 1 }
    ]) {
      expect(tool.schema.safeParse({ todos: [todo] }).success).toBe(false)
    }
  })

  it('trims surrounding whitespace and rejects an oversized write', () => {
    const parsed = tool.schema.parse({ todos: [{ id: '  a  ', content: '  Task  ', status: 'pending' }] })
    expect(parsed.todos).toEqual([{ id: 'a', content: 'Task', status: 'pending' }])

    const oversized = Array.from({ length: 257 }, (_item, index) => ({
      id: `item-${index}`,
      content: 'Task',
      status: 'pending' as const
    }))
    expect(tool.schema.safeParse({ todos: oversized }).success).toBe(false)
  })
})

describe('todo store', () => {
  const item = (id: string, content: string, status: 'pending' | 'completed' = 'pending') => ({
    id,
    content,
    status
  })

  it('replaces the list by default and keeps the last write of a repeated id', () => {
    const store = new TodoStore()
    store.write([item('a', 'First'), item('b', 'Second')])

    expect(store.write([item('c', 'Third'), item('a', 'Stale'), item('a', 'Fresh', 'completed')])).toEqual([
      item('c', 'Third'),
      item('a', 'Fresh', 'completed')
    ])
  })

  it('overwrites by id and appends new items in place when merging', () => {
    const store = new TodoStore()
    store.write([item('a', 'First'), item('b', 'Second')])

    expect(store.write([item('b', 'Second done', 'completed'), item('c', 'Third')], true)).toEqual([
      item('a', 'First'),
      item('b', 'Second done', 'completed'),
      item('c', 'Third')
    ])
  })

  it('caps the list that merging accumulates across calls', () => {
    const store = new TodoStore()
    for (let batch = 0; batch < 3; batch++) {
      store.write(
        Array.from({ length: 100 }, (_item, index) => item(`item-${batch}-${index}`, 'Task')),
        true
      )
    }

    const stored = store.read()
    expect(stored).toHaveLength(256)
    expect(stored[0]!.id).toBe('item-0-0')
    expect(stored.at(-1)!.id).toBe('item-2-55')
  })

  it('hands out copies so a caller cannot mutate stored items', () => {
    const store = new TodoStore()
    const written = store.write([item('a', 'First')])
    written[0]!.content = 'Mutated'

    expect(store.read()).toEqual([item('a', 'First')])
  })
})
