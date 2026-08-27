import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { jsonToolResult } from '../../core/tool-result'

const VALID_STATUSES = ['pending', 'in_progress', 'completed', 'cancelled'] as const
// Caps bound how much a misbehaving model can grow the list. The list lives in
// the context window every turn, so it has to stay small. A single oversized
// write is rejected by the schema; `merge` accumulates across calls, so the
// store enforces the item cap as well.
const MAX_TODO_CONTENT_CHARS = 4000
const MAX_TODO_ITEMS = 256

export type TodoStatus = (typeof VALID_STATUSES)[number]

export interface TodoItem {
  id: string
  content: string
  status: TodoStatus
}

export interface TodoSummary {
  total: number
  pending: number
  in_progress: number
  completed: number
  cancelled: number
}

export interface TodoToolDetails {
  todos: TodoItem[]
  summary: TodoSummary
}

// The schema is the model's contract, and the only place a write is validated:
// the agent loop rejects a call that fails it before `execute` runs, so the
// store below can trust every item it receives. Omitting `todos` entirely means
// "read", which is why the field is optional rather than a separate read tool.
const TodoItemParams = z
  .object({
    id: z.string().trim().min(1).describe('Unique item identifier.'),
    content: z.string().trim().min(1).max(MAX_TODO_CONTENT_CHARS).describe('Task description.'),
    status: z.enum(VALID_STATUSES).describe('Current status.')
  })
  .strict()

const TodoParams = z
  .object({
    todos: z
      .array(TodoItemParams)
      .max(MAX_TODO_ITEMS)
      .describe('Task items to write. Omit to read current list.')
      .optional(),
    merge: z
      .boolean()
      .describe('true: update existing items by id and add new ones. false: replace the entire list.')
      .meta({ default: false })
      .optional()
  })
  .strict()

type TodoParams = z.output<typeof TodoParams>

// Model-facing usage guide. The behavioral rules near the end ("one item
// in_progress at a time", "mark completed immediately", "cancel on failure")
// are the contract the rest of the runtime relies on when it renders or
// summarizes the plan; they are instructions to the model, not enforced here.
const DESCRIPTION = [
  'Manage your task list for the current session. Use for complex tasks with 3+ steps or when the user provides multiple tasks.',
  'List order is priority. Only ONE item in_progress at a time.',
  'Mark items completed immediately when done. If something fails, cancel it and add a revised item.',
  'Always returns the full current list.'
].join('\n')

/**
 * The session's task list, held in memory for one run. `read`/`snapshot` hand
 * out copies so a caller cannot mutate the store's items in place.
 */
export class TodoStore {
  private items: TodoItem[] = []

  read(): TodoItem[] {
    return this.items.map(item => ({ ...item }))
  }

  hasItems(): boolean {
    return this.items.length > 0
  }

  /**
   * Applies a validated write. With `merge=false` the list is replaced
   * wholesale (a fresh plan). With `merge=true` existing items are overwritten
   * by id and unknown ids are appended, preserving the order the model last
   * sent.
   */
  write(todos: TodoItem[], merge = false): TodoItem[] {
    const incoming = dedupeByID(todos)
    if (!merge) {
      this.items = incoming
    } else {
      const merged = new Map<string, TodoItem>(this.items.map(item => [item.id, item]))
      for (const item of incoming) merged.set(item.id, item)
      this.items = [...merged.values()]
    }

    // `merge` accumulates across calls, so this is the only place the item cap
    // holds. Keeps the earliest items — list order is the model's stated
    // priority, so the cap drops the lowest-priority tail.
    if (this.items.length > MAX_TODO_ITEMS) this.items = this.items.slice(0, MAX_TODO_ITEMS)
    return this.read()
  }

  snapshot(): TodoToolDetails {
    const todos = this.read()
    return { todos, summary: summarizeTodos(todos) }
  }
}

// Collapses repeated ids in one payload. Re-setting a key keeps its first
// position and takes the last value, so a later edit in the same call wins
// without moving the item.
function dedupeByID(todos: TodoItem[]): TodoItem[] {
  const byID = new Map<string, TodoItem>()
  for (const item of todos) byID.set(item.id, { ...item })
  return [...byID.values()]
}

/**
 * Builds the `todo` tool over a run-scoped store. Reading and writing share one
 * entry point: a write only happens when `todos` is present, otherwise the call
 * is a pure read. Either way the full current list is returned, so the model
 * always sees the post-write state.
 */
export function createTodoTool(store: TodoStore): WorkerAgentTool<typeof TodoParams, TodoToolDetails> {
  return defineWorkerTool({
    name: 'todo',
    description: DESCRIPTION,
    schema: TodoParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => null,
    async execute(toolCallID, params): Promise<AgentToolResult<TodoToolDetails>> {
      if (params.todos !== undefined) store.write(params.todos, params.merge ?? false)
      const details = store.snapshot()
      return jsonToolResult(details, {
        presentation: [
          {
            kind: 'plan.snapshot',
            payload: {
              operation_id: toolCallID,
              items: details.todos.map(item => ({
                id: item.id,
                content: item.content,
                status: item.status
              }))
            }
          }
        ]
      })
    }
  })
}

/**
 * Counts todo items by status for the tool's structured details.
 */
function summarizeTodos(todos: TodoItem[]): TodoSummary {
  return {
    total: todos.length,
    pending: todos.filter(item => item.status === 'pending').length,
    in_progress: todos.filter(item => item.status === 'in_progress').length,
    completed: todos.filter(item => item.status === 'completed').length,
    cancelled: todos.filter(item => item.status === 'cancelled').length
  }
}
