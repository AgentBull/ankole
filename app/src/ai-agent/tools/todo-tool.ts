import { z } from 'zod'
import { isPlainObject } from '@pleisto/active-support'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'

const VALID_STATUSES = ['pending', 'in_progress', 'completed', 'cancelled'] as const
const VALID_STATUS_SET = new Set<string>(VALID_STATUSES)
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

const DESCRIPTION = [
  'Manage your task list for the current session. Use for complex tasks with 3+ steps or when the user provides multiple tasks. Call with no parameters to read the current list.',
  '',
  'Writing:',
  "- Provide 'todos' array to create/update items",
  '- merge=false (default): replace the entire list with a fresh plan',
  '- merge=true: update existing items by id, add any new ones',
  '',
  'Each item: {id: string, content: string, status: pending|in_progress|completed|cancelled}',
  'List order is priority. Only ONE item in_progress at a time.',
  'Mark items completed immediately when done. If something fails, cancel it and add a revised item.',
  '',
  'Always returns the full current list.'
].join('\n')

export class TodoStore {
  private items: TodoItem[] = []

  read(): TodoItem[] {
    return this.items.map(item => ({ ...item }))
  }

  hasItems(): boolean {
    return this.items.length > 0
  }

  write(todos: unknown[], merge = false): TodoItem[] {
    if (!merge) {
      this.items = this.dedupeById(todos).map(item => this.validate(item))
    } else {
      const existing = new Map<string, TodoItem>(this.items.map(item => [item.id, { ...item }]))
      for (const item of this.dedupeById(todos)) {
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

    if (this.items.length > MAX_TODO_ITEMS) this.items = this.items.slice(0, MAX_TODO_ITEMS)
    return this.read()
  }

  hydrate(todos: unknown): void {
    if (!Array.isArray(todos)) return
    this.write(todos, false)
  }

  snapshot(): TodoToolDetails {
    const todos = this.read()
    return { todos, summary: summarizeTodos(todos) }
  }

  formatActiveSnapshot(): string | undefined {
    const active = this.items.filter(item => item.status === 'pending' || item.status === 'in_progress')
    if (active.length === 0) return undefined

    const marker = {
      pending: '[ ]',
      in_progress: '[>]',
      completed: '[x]',
      cancelled: '[~]'
    } satisfies Record<TodoStatus, string>

    return [
      '[Your active task list was preserved for this conversation]',
      ...active.map(item => `- ${marker[item.status]} ${item.id}. ${item.content} (${item.status})`)
    ].join('\n')
  }

  private validate(item: unknown): TodoItem {
    const id = normalizeStringField(item, 'id') || '?'
    const content = normalizeStringField(item, 'content') || '(no description)'
    return {
      id,
      content: capContent(content),
      status: normalizeStatus(normalizeStringField(item, 'status')) ?? 'pending'
    }
  }

  private dedupeById(todos: unknown[]): unknown[] {
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

export function createTodoTool(store: TodoStore): AgentTool<typeof TodoParams, TodoToolDetails> {
  return buildTool({
    name: 'todo',
    label: 'Todo',
    description: DESCRIPTION,
    schema: TodoParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<TodoToolDetails>> {
      if (params.todos !== undefined) store.write(params.todos, params.merge ?? false)
      const details = store.snapshot()
      return {
        content: [{ type: 'text', text: JSON.stringify(details) }],
        details
      }
    }
  })
}

export function summarizeTodos(todos: TodoItem[]): TodoSummary {
  return {
    total: todos.length,
    pending: todos.filter(item => item.status === 'pending').length,
    in_progress: todos.filter(item => item.status === 'in_progress').length,
    completed: todos.filter(item => item.status === 'completed').length,
    cancelled: todos.filter(item => item.status === 'cancelled').length
  }
}

export function todoItemsFromToolDetails(details: unknown): TodoItem[] | undefined {
  if (!isPlainObject(details)) return undefined
  if (!Array.isArray(details.todos)) return undefined
  const store = new TodoStore()
  store.hydrate(details.todos)
  return store.read()
}

function normalizeStringField(item: unknown, field: string): string {
  if (!isPlainObject(item)) return ''
  const value = item[field]
  return value === undefined || value === null ? '' : String(value).trim()
}

function normalizeStatus(value: string): TodoStatus | undefined {
  const status = value.toLowerCase()
  return VALID_STATUS_SET.has(status) ? (status as TodoStatus) : undefined
}

function capContent(content: string): string {
  if (content.length <= MAX_TODO_CONTENT_CHARS) return content
  return content.slice(0, MAX_TODO_CONTENT_CHARS - TRUNCATION_MARKER.length) + TRUNCATION_MARKER
}
