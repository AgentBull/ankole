import type { Root } from 'mdast'
import { parseMarkdown, toPlainText } from './markdown'
import { POSTABLE_OBJECT, type PostableObject, type PostableObjectContext } from './postable-object'
import type { Adapter } from './types'

// =============================================================================
// Plan Types (moved from types.ts per review feedback)
// =============================================================================

export type PlanTaskStatus = 'pending' | 'in_progress' | 'complete' | 'error'

export interface PlanTask {
  id: string
  status: PlanTaskStatus
  title: string
}

export interface PlanModel {
  tasks: PlanModelTask[]
  title: string
}

export interface PlanModelTask {
  details?: PlanContent
  id: string
  output?: PlanContent
  status: PlanTaskStatus
  title: string
}

export type PlanContent = string | string[] | { markdown: string } | { ast: Root }

export interface StartPlanOptions {
  /** Initial plan title and first task title */
  initialMessage: PlanContent
}

export interface AddTaskOptions {
  /** Task details/substeps. */
  children?: PlanContent
  title: PlanContent
}

export type UpdateTaskInput =
  | PlanContent
  | {
      /** Task ID to update. If omitted, updates the last in_progress task. */
      id?: string
      /** Task output/results. */
      output?: PlanContent
      /** Optional status override. */
      status?: PlanTaskStatus
    }

export interface CompletePlanOptions {
  /** Final plan title shown when completed */
  completeMessage: PlanContent
}

// =============================================================================
// Plan Implementation
// =============================================================================

/**
 * Convert PlanContent to plain text for titles/labels.
 */
function contentToPlainText(content: PlanContent | undefined): string {
  if (!content) {
    return ''
  }
  if (Array.isArray(content)) {
    return content.join(' ').trim()
  }
  if (typeof content === 'string') {
    return content
  }
  if ('markdown' in content) {
    return toPlainText(parseMarkdown(content.markdown))
  }
  if ('ast' in content) {
    return toPlainText(content.ast)
  }
  return ''
}

interface PostedState {
  messageId: string
  threadId: string
}

/**
 * A Plan represents a task list that can be posted to a thread.
 *
 * Create a plan with `new Plan({ initialMessage: "..." })`, build the snapshot
 * with methods like `addTask()`, `updateTask()`, and `complete()`, then post it.
 * External Gateway does not edit already-posted provider messages.
 *
 * @example
 * ```typescript
 * const plan = new Plan({ initialMessage: "Starting task..." });
 * await plan.addTask({ title: "Fetch data" });
 * await plan.updateTask("Got 42 results");
 * await plan.complete({ completeMessage: "Done!" });
 * await thread.post(plan);
 * ```
 */
export class Plan implements PostableObject<PlanModel> {
  readonly $$typeof = POSTABLE_OBJECT
  readonly kind = 'plan'

  private _model: PlanModel
  private _posted: PostedState | null = null

  constructor(options: StartPlanOptions) {
    const title = contentToPlainText(options.initialMessage) || 'Plan'
    const firstTask: PlanModelTask = {
      id: crypto.randomUUID(),
      title,
      status: 'in_progress'
    }
    this._model = { title, tasks: [firstTask] }
  }

  isSupported(adapter: Adapter): boolean {
    return !!adapter.postObject
  }

  getPostData(): PlanModel {
    return this._model
  }

  getFallbackText(): string {
    const lines: string[] = []
    lines.push(`📋 ${this._model.title || 'Plan'}`)
    for (const task of this._model.tasks) {
      const statusIcons: Record<string, string> = {
        complete: '✅',
        in_progress: '🔄',
        error: '❌'
      }
      const statusIcon = statusIcons[task.status] ?? '⬜'
      lines.push(`${statusIcon} ${task.title}`)
    }
    return lines.join('\n')
  }

  onPosted(context: PostableObjectContext): void {
    this._posted = {
      messageId: context.messageId,
      threadId: context.threadId
    }
  }

  get id(): string {
    return this._posted?.messageId ?? ''
  }
  get threadId(): string {
    return this._posted?.threadId ?? ''
  }
  get title(): string {
    return this._model.title
  }
  get tasks(): readonly PlanTask[] {
    return this._model.tasks.map(t => ({
      id: t.id,
      title: t.title,
      status: t.status
    }))
  }
  get currentTask(): PlanTask | null {
    let current: PlanModelTask | undefined
    for (let i = this._model.tasks.length - 1; i >= 0; i--) {
      if (this._model.tasks[i].status === 'in_progress') {
        current = this._model.tasks[i]
        break
      }
    }
    current ??= this._model.tasks.at(-1)
    if (!current) {
      return null
    }
    return { id: current.id, title: current.title, status: current.status }
  }

  async addTask(options: AddTaskOptions): Promise<PlanTask | null> {
    const title = contentToPlainText(options.title) || 'Task'
    for (const task of this._model.tasks) {
      if (task.status === 'in_progress') {
        task.status = 'complete'
      }
    }
    const nextTask: PlanModelTask = {
      id: crypto.randomUUID(),
      title,
      status: 'in_progress',
      details: options.children
    }
    this._model.tasks.push(nextTask)
    this._model.title = title

    return { id: nextTask.id, title: nextTask.title, status: nextTask.status }
  }

  async updateTask(update?: UpdateTaskInput): Promise<PlanTask | null> {
    let current: PlanModelTask | undefined
    if (typeof update === 'object' && update !== null && 'id' in update && update.id) {
      current = this._model.tasks.find(t => t.id === update.id)
    } else {
      for (let i = this._model.tasks.length - 1; i >= 0; i--) {
        if (this._model.tasks[i].status === 'in_progress') {
          current = this._model.tasks[i]
          break
        }
      }
      current ??= this._model.tasks.at(-1)
    }

    if (!current) {
      return null
    }
    if (update !== undefined) {
      if (typeof update === 'object' && update !== null && 'output' in update) {
        if (update.output !== undefined) {
          current.output = update.output
        }
        if (update.status) {
          current.status = update.status
        }
      } else {
        current.output = update as PlanContent
      }
    }
    return { id: current.id, title: current.title, status: current.status }
  }

  async reset(options: StartPlanOptions): Promise<PlanTask | null> {
    const title = contentToPlainText(options.initialMessage) || 'Plan'
    const firstTask: PlanModelTask = {
      id: crypto.randomUUID(),
      title,
      status: 'in_progress'
    }
    this._model = { title, tasks: [firstTask] }

    return {
      id: firstTask.id,
      title: firstTask.title,
      status: firstTask.status
    }
  }

  async complete(options: CompletePlanOptions): Promise<void> {
    for (const task of this._model.tasks) {
      if (task.status === 'in_progress') {
        task.status = 'complete'
      }
    }
    this._model.title = contentToPlainText(options.completeMessage) || this._model.title
  }
}
