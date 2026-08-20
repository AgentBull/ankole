import { z } from 'zod'
import { isRecord } from '@agentbull/active-support'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { jsonToolResult } from '../../core/tool-result'

const VALID_STATUSES = ['pending', 'in_progress', 'completed', 'cancelled'] as const
const VALID_STATUS_SET = new Set<string>(VALID_STATUSES)
// Caps bound how much a misbehaving model can grow the list. Oversized content
// is truncated; excess items are dropped. The list lives in the context window
// every turn, so it has to stay small.
const MAX_TODO_CONTENT_CHARS = 4000
const MAX_TODO_ITEMS = 256
const TRUNCATION_MARKER = ' [truncated]'

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

// The schema is the model's contract. Omitting `todos` entirely means "read",
// which is why the field is optional rather than a separate read tool.
const TodoItemParams = z.object({
  id: z.string().describe('Unique item identifier.'),
  content: z.string().describe('Task description.'),
  status: z.enum(VALID_STATUSES).describe('Current status.')
})

const TodoParams = z.object({
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
 * The session's task list, held in memory for one run. Every write is
 * normalized and bounded here so the rest of the runtime can trust the shape
 * regardless of what the model sent. `read`/`snapshot` hand out copies so a
 * caller cannot mutate the store's items in place.
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
   * Applies a model-supplied write. With `merge=false` the list is replaced
   * wholesale (a fresh plan). With `merge=true` existing items are patched by
   * id and unknown ids are appended, preserving the order the model last sent.
   * Input is untrusted (`unknown[]`): every item is normalized and capped, so a
   * malformed payload degrades to placeholders instead of throwing.
   */
  write(todos: unknown[], merge = false): TodoItem[] {
    if (!merge) {
      this.items = this.dedupeByID(todos).map(item => this.validate(item))
    } else {
      // Patch existing items in place by id; append genuinely new ones. A blank
      // id is skipped (cannot be addressed). For a patch, only fields the model
      // actually sent overwrite the current value, so a partial update like
      // {id, status} keeps the existing content.
      const existing = new Map<string, TodoItem>(this.items.map(item => [item.id, { ...item }]))
      for (const item of this.dedupeByID(todos)) {
        const id = normalizeStringField(item, 'id')
        if (!id) continue
        const current = existing.get(id)
        if (current) {
          const content = normalizeStringField(item, 'content')
          const status = normalizeStatus(normalizeStringField(item, 'status'))
          if (content) current.content = capContent(content)
          if (status) current.status = status
          existing.set(id, current)
        } else {
          const validated = this.validate(item)
          existing.set(validated.id, validated)
          this.items.push(validated)
        }
      }

      // Rebuild the list in original order, swapping in the patched copies and
      // dropping any duplicate ids that slipped in. The append above pushes new
      // items onto `this.items`, so iterating it here also picks them up.
      const seen = new Set<string>()
      const rebuilt: TodoItem[] = []
      for (const item of this.items) {
        const current = existing.get(item.id) ?? item
        if (seen.has(current.id)) continue
        rebuilt.push({ ...current })
        seen.add(current.id)
      }
      this.items = rebuilt
    }

    // Final hard cap. Keeps the earliest items (list order is the model's stated
    // priority), so the cap drops the lowest-priority tail.
    if (this.items.length > MAX_TODO_ITEMS) this.items = this.items.slice(0, MAX_TODO_ITEMS)
    return this.read()
  }

  snapshot(): TodoToolDetails {
    const todos = this.read()
    return { todos, summary: summarizeTodos(todos) }
  }

  // Coerces one untrusted item into a well-formed TodoItem. Missing id/content
  // fall back to placeholders and an unknown status defaults to 'pending', so a
  // bad item is never dropped silently — it shows up visibly instead.
  private validate(item: unknown): TodoItem {
    const id = normalizeStringField(item, 'id') || '?'
    const content = normalizeStringField(item, 'content') || '(no description)'
    return {
      id,
      content: capContent(content),
      status: normalizeStatus(normalizeStringField(item, 'status')) ?? 'pending'
    }
  }

  // Collapses repeated ids in a single payload, keeping the LAST occurrence (so
  // a later edit in the same call wins) while preserving first-seen order. Items
  // with no id collapse under the shared '?' key. Done by recording each id's
  // last index, then replaying those indices in ascending order.
  private dedupeByID(todos: unknown[]): unknown[] {
    const lastIndex = new Map<string, number>()
    todos.forEach((item, index) => {
      const id = normalizeStringField(item, 'id') || '?'
      lastIndex.set(id, index)
    })
    return [...lastIndex.values()]
      .sort((left, right) => left - right)
      .flatMap(index => (todos[index] === undefined ? [] : [todos[index]]))
  }
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

// Reads one field off an untrusted item as a trimmed string. Anything that is
// not an object, or a null/undefined field, becomes ''. Other types are
// coerced with String() so e.g. a numeric id still survives.
function normalizeStringField(item: unknown, field: string): string {
  if (!isRecord(item)) return ''
  const value = item[field]
  return value === undefined || value === null ? '' : String(value).trim()
}

// Accepts a status only if it is one of the four known values (case-insensitive);
// returns undefined otherwise so callers can fall back to a default.
function normalizeStatus(value: string): TodoStatus | undefined {
  const status = value.toLowerCase()
  return VALID_STATUS_SET.has(status) ? (status as TodoStatus) : undefined
}

// Trims overlong content to the cap, reserving room for the marker so the result
// stays within MAX_TODO_CONTENT_CHARS and the truncation is visible to the model.
function capContent(content: string): string {
  if (content.length <= MAX_TODO_CONTENT_CHARS) return content
  return content.slice(0, MAX_TODO_CONTENT_CHARS - TRUNCATION_MARKER.length) + TRUNCATION_MARKER
}
