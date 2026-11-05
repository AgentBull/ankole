import type { ConversationExecutionItem, ExecutionStep } from './types'

export type WorkGroupSegment = {
  kind: 'work_group'
  id: string
  reasoning: string[]
  steps: ExecutionStep[]
  spawnedThreadIDs: string[]
  defaultOpen: boolean
}

export type NarrativeSegment =
  | { kind: 'steer'; id: string; text: string }
  | { kind: 'message'; id: string; text: string; phase?: string }
  | WorkGroupSegment

export function isStepActive(step: ExecutionStep): boolean {
  return ![
    'completed',
    'complete',
    'success',
    'succeeded',
    'settled',
    'stopped',
    'cancelled',
    'failed',
    'error'
  ].includes(step.status)
}

export function executionItemToStep(item: ConversationExecutionItem): ExecutionStep {
  const tool =
    item.tool ||
    (item.toolKind === 'command'
      ? 'command'
      : item.toolKind === 'patch'
        ? 'apply_patch'
        : item.toolKind === 'skill'
          ? 'skill_view'
          : 'tool')

  let input: unknown = item.input ?? undefined
  let output: unknown = item.output ?? item.error ?? undefined

  if (item.command) {
    input = {
      command: item.command.command ?? '',
      workdir: item.command.cwd ?? undefined
    }
    output = {
      stdout: item.command.output ?? undefined,
      exitCode: item.command.exitCode ?? undefined
    }
  } else if (item.collab) {
    input = item.collab.prompt ?? undefined
    output = item.collab.agentSummary ?? item.output ?? undefined
  }

  return {
    id: item.id,
    tool,
    toolKind: item.toolKind ?? undefined,
    title: item.title || tool,
    skill_name: item.skillName ?? undefined,
    status: item.status || 'completed',
    duration_ms: item.durationMs ?? undefined,
    input,
    output,
    files: item.files ?? undefined
  }
}

export function buildNarrativeSegments(items: ConversationExecutionItem[], isLiveRun: boolean): NarrativeSegment[] {
  const seen = new Set<string>()
  const deduped: ConversationExecutionItem[] = []
  for (const item of items) {
    if (seen.has(item.id)) continue
    seen.add(item.id)
    deduped.push(item)
  }

  const hasMessages = deduped.some(item => item.kind === 'message' && Boolean(item.text?.trim()))
  const segments: NarrativeSegment[] = []
  let pendingGroup: Omit<WorkGroupSegment, 'defaultOpen'> | null = null

  const flushGroup = () => {
    if (!pendingGroup) return
    if (pendingGroup.steps.length > 0 || pendingGroup.reasoning.length > 0) {
      segments.push({ ...pendingGroup, defaultOpen: false })
    }
    pendingGroup = null
  }

  const ensureGroup = (seedID: string) => {
    if (!pendingGroup) {
      pendingGroup = {
        kind: 'work_group',
        id: `group:${seedID}`,
        reasoning: [],
        steps: [],
        spawnedThreadIDs: []
      }
    }
    return pendingGroup
  }

  for (const item of deduped) {
    if (item.kind === 'steer_message') {
      const text = item.text?.trim()
      if (!text) continue
      flushGroup()
      segments.push({ kind: 'steer', id: item.id, text })
    } else if (item.kind === 'message') {
      const text = item.text?.trim()
      if (!text) continue
      flushGroup()
      segments.push({ kind: 'message', id: item.id, text: item.text!, phase: item.phase ?? undefined })
    } else if (item.kind === 'reasoning') {
      const text = item.text?.trim()
      if (!text) continue
      ensureGroup(item.id).reasoning.push(text)
    } else if (item.kind === 'tool') {
      const group = ensureGroup(item.id)
      group.steps.push(executionItemToStep(item))
      for (const threadID of item.collab?.receiverThreadIDs ?? []) {
        if (threadID && !group.spawnedThreadIDs.includes(threadID)) {
          group.spawnedThreadIDs.push(threadID)
        }
      }
    }
  }
  flushGroup()

  return segments.map((segment, index) => {
    if (segment.kind !== 'work_group') return segment
    const isTail = index === segments.length - 1
    const hasFailed = segment.steps.some(step => ['failed', 'error'].includes(step.status))
    const hasRunning = segment.steps.some(isStepActive)
    return {
      ...segment,
      defaultOpen: hasFailed || hasRunning || (isLiveRun && isTail) || !hasMessages
    }
  })
}

function normalizeComparable(value: string): string {
  return value.replace(/\s+/g, ' ').trim()
}

export function shouldShowOutcomeSummary(
  outcomeText: string | null | undefined,
  items: ConversationExecutionItem[]
): boolean {
  if (!outcomeText) return false
  const trimmed = outcomeText.trim()
  if (!trimmed || trimmed === '{}' || trimmed === '[]' || trimmed === 'null' || trimmed === '""') return false
  const lastMessage = items.findLast(item => item.kind === 'message' && Boolean(item.text?.trim()))
  if (lastMessage?.text && normalizeComparable(lastMessage.text) === normalizeComparable(trimmed)) {
    return false
  }
  return true
}
