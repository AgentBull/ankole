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
