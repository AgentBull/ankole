import {
  RiCheckLine,
  RiCloseLine,
  RiDatabase2Line,
  RiFileEditLine,
  RiFileTextLine,
  RiNodeTree,
  RiSearchLine,
  RiSparklingLine,
  RiStopFill,
  RiTerminalBoxLine,
  RiToolsLine
} from '@remixicon/react'
import type { TFunction } from 'i18next'
import { Spinner } from '@ankole/uikit'
import type { SyntheticEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { isRecord, safeJsonParse } from '@agentbull/active-support'
import { humanizeTechnicalLabel } from '../../common/humanize-technical-label'
import type { ExecutionStep } from './types'

function ToolIcon({ tool, toolKind }: { tool: string; toolKind?: string }) {
  const Icon =
    toolKind === 'skill' || tool === 'skill_view'
      ? RiSparklingLine
      : toolKind === 'patch' || tool === 'apply_patch' || /edit_file|write_file/.test(tool)
        ? RiFileEditLine
        : toolKind === 'collab' || /spawnAgent|sendInput|resumeAgent|closeAgent|background_job|workflow/.test(tool)
          ? RiNodeTree
          : /bash|terminal|command|shell/.test(tool)
            ? RiTerminalBoxLine
            : /base|db\.|query/.test(tool)
              ? RiDatabase2Line
              : toolKind === 'search' || /brain|search|memory/.test(tool)
                ? RiSearchLine
                : /page|file|read/.test(tool)
                  ? RiFileTextLine
                  : RiToolsLine
  return <Icon aria-hidden />
}

function decoded(value: unknown): unknown {
  if (typeof value !== 'string') return value
  return safeJsonParse(value).unwrapOr(value)
}

export function formatToolDetail(value: unknown): string | undefined {
  if (value == null) return undefined
  const parsed = decoded(value)
  if (parsed == null) return undefined
  if (typeof parsed === 'string') {
    const trimmed = parsed.trim()
    if (!trimmed || trimmed === '{}' || trimmed === '[]' || trimmed === 'null' || /^<skill\b/i.test(trimmed)) {
      return undefined
    }
    return parsed
  }
  if (Array.isArray(parsed)) {
    if (!parsed.length) return undefined
    const texts = parsed
      .map(entry => (isRecord(entry) && typeof entry.text === 'string' ? entry.text : undefined))
      .filter((entry): entry is string => Boolean(entry && entry.trim()))
    if (texts.length === parsed.length) {
      const visible = texts.filter(text => !/^<skill\b/i.test(text.trim()))
      return visible.length ? visible.join('\n') : undefined
    }
    return JSON.stringify(parsed, null, 2)
  }
  if (isRecord(parsed)) return Object.keys(parsed).length ? JSON.stringify(parsed, null, 2) : undefined
  return JSON.stringify(parsed, null, 2)
}

export function humanizeToolName(tool: string): string {
  const cleaned = tool.replace(/^mcp__[^_]+__/, '').replace(/[.:/]+/g, '_')
  return humanizeTechnicalLabel(cleaned) || tool
}

export function skillStepName(
  step: Pick<ExecutionStep, 'tool' | 'toolKind' | 'title' | 'skill_name' | 'input'> & { status?: string }
): string | undefined {
  if (step.status && ['failed', 'error'].includes(step.status)) return undefined
  if (step.skill_name && step.skill_name.trim()) return step.skill_name.trim()
  const isSkill = step.tool === 'skill_view' || step.toolKind === 'skill'
  const input = decoded(step.input)
  if (isSkill) {
    if (isRecord(input) && typeof input.name === 'string' && input.name.trim()) return input.name.trim()
    const match = /^Load skill:\s*(.+)$/i.exec(step.title || '')
    if (match?.[1]?.trim()) return match[1].trim()
    if (step.title && step.title !== 'skill_view' && !/skill.?view/i.test(step.title)) return step.title.trim()
    return ''
  }
  if (step.tool === 'read_file' && isRecord(input) && typeof input.path === 'string') {
    const skillMatch = /(?:^|\/)([^/]+)\/SKILL\.md$/i.exec(input.path.trim())
    if (skillMatch?.[1]) return skillMatch[1]
  }
  return undefined
}

/** A step reads as the localized activity label that people saw while it ran, when it has one. */
export function stepTitle(
  step: Pick<ExecutionStep, 'title' | 'tool'> & Partial<Pick<ExecutionStep, 'label_key' | 'label_bindings'>>,
  t?: TFunction
): string {
  const fallback = step.title && step.title !== step.tool ? step.title : humanizeToolName(step.tool)
  return t && step.label_key ? t(step.label_key, { ...step.label_bindings, defaultValue: fallback }) : fallback
}

export function localizedStepTitle(
  step: Pick<ExecutionStep, 'title' | 'tool' | 'toolKind' | 'skill_name' | 'input' | 'files'> &
    Partial<Pick<ExecutionStep, 'label_key' | 'label_bindings'>> & { status?: string },
  t: TFunction
): string {
  const skill = skillStepName(step)
  if (skill !== undefined) {
    return skill
      ? t('pod.chat_timeline.skill_loaded_named', { name: skill })
      : t('pod.chat_timeline.skill_loaded_generic')
  }
  if (step.label_key) return stepTitle(step, t)

  const input = decoded(step.input)
  const argObj = isRecord(input) ? input : undefined

  if (step.tool === 'create_background_job') {
    const target = typeof argObj?.title === 'string' && argObj.title.trim() ? argObj.title.trim() : undefined
    return target ? `${t('pod.chat_timeline.tool_create_job')} · ${target}` : t('pod.chat_timeline.tool_create_job')
  }
  if (step.tool === 'respawn_background_job') return t('pod.chat_timeline.tool_respawn_job')
  if (step.tool === 'send_message_to_background_job') return t('pod.chat_timeline.tool_message_job')
  if (step.tool === 'stop_background_job') return t('pod.chat_timeline.tool_stop_job')
  if (step.tool === 'workflow') {
    const target = typeof argObj?.title === 'string' && argObj.title.trim() ? argObj.title.trim() : undefined
    return target ? `${t('pod.chat_timeline.tool_run_workflow')} · ${target}` : t('pod.chat_timeline.tool_run_workflow')
  }
  if (step.tool === 'cancel_workflow') return t('pod.chat_timeline.tool_stop_workflow')

  if (step.tool === 'apply_patch' || step.toolKind === 'patch') {
    if (step.files?.length === 1 && step.files[0]?.path) {
      return t('pod.chat_timeline.tool_patch_target', { target: step.files[0].path })
    }
    if (step.title && step.title !== 'apply_patch' && step.title !== 'Apply patch') {
      return t('pod.chat_timeline.tool_patch_target', { target: step.title })
    }
    return t('pod.chat_timeline.tool_apply_patch')
  }

  if (step.tool === 'spawnAgent') return t('pod.chat_timeline.tool_collab_spawn')
  if (step.tool === 'sendInput' || step.tool === 'resumeAgent') return t('pod.chat_timeline.tool_collab_send')
  if (step.tool === 'wait') return t('pod.chat_timeline.tool_collab_wait')
  if (step.tool === 'closeAgent') return t('pod.chat_timeline.tool_collab_close')

  if ((step.tool === 'web_search' || step.tool === 'web_search_call') && step.title) {
    const query = step.title.replace(/^Search web:\s*/i, '').trim()
    if (query && query !== step.tool && query !== 'Search web') {
      return t('pod.chat_timeline.tool_search_web', { query })
    }
  }
  if (step.tool === 'brain.search' && step.title) {
    const query = step.title.replace(/^Search memory:\s*/i, '').trim()
    if (query && query !== step.tool && query !== 'Search memory') {
      return t('pod.chat_timeline.tool_search_memory', { query })
    }
  }
  if (step.tool === 'read_file' && typeof argObj?.path === 'string' && argObj.path.trim()) {
    return t('pod.chat_timeline.tool_read_file', { path: argObj.path.trim() })
  }
  if (step.tool === 'write_file' && typeof argObj?.path === 'string' && argObj.path.trim()) {
    return t('pod.chat_timeline.tool_write_file', { path: argObj.path.trim() })
  }
  if (step.tool === 'command' && step.title?.startsWith('Run command: ')) {
    return step.title.slice('Run command: '.length)
  }

  return stepTitle(step, t)
}

export function commandDetails(step: ExecutionStep) {
  const input = decoded(step.input)
  if (!/bash|terminal|command|shell/.test(step.tool) || !isRecord(input) || typeof input.command !== 'string') {
    return undefined
  }
  const output = decoded(step.output)
  const value = isRecord(output) ? output : undefined
  const text = typeof output === 'string' ? output : typeof value?.output === 'string' ? value.output : ''
  const prefix = /^exit_code=(-?\d+)\r?\nduration=[^\r\n]+(?:\r?\n|$)/.exec(text)
  const exitCode = prefix
    ? Number(prefix[1])
    : typeof value?.exitCode === 'number'
      ? value.exitCode
      : typeof value?.exit_code === 'number'
        ? value.exit_code
        : undefined
  const stdout =
    typeof value?.stdout === 'string'
      ? value.stdout
      : prefix
        ? text.slice(prefix[0].length)
        : text ||
          (value && ['stdout', 'stderr', 'exitCode', 'exit_code'].some(key => key in value)
            ? undefined
            : formatToolDetail(step.output))
  return {
    command: input.command,
    workdir: typeof input.workdir === 'string' ? input.workdir : typeof input.cwd === 'string' ? input.cwd : undefined,
    stdout,
    stderr: typeof value?.stderr === 'string' ? value.stderr : undefined,
    exitCode
  }
}

type PatchLine = { marker: '+' | '-' | ' ' | '@'; text: string }
type PatchFile = {
  path: string
  movePath?: string
  kind: 'add' | 'delete' | 'update'
  added: number
  removed: number
  lines: PatchLine[]
}

function parseUnifiedDiffLines(diff: string | null | undefined): {
  lines: PatchLine[]
  added: number
  removed: number
} {
  if (!diff || !diff.trim()) return { lines: [], added: 0, removed: 0 }
  const lines: PatchLine[] = []
  let added = 0
  let removed = 0
  for (const raw of diff.split(/\r?\n/)) {
    if (raw.startsWith('--- ') || raw.startsWith('+++ ') || raw.startsWith('diff --git ') || raw.startsWith('index ')) {
      continue
    }
    if (raw.startsWith('@@')) {
      lines.push({ marker: '@', text: raw.slice(2).trim() })
    } else if (raw[0] === '+' || raw[0] === '-' || raw[0] === ' ') {
      if (raw[0] === '+') added += 1
      if (raw[0] === '-') removed += 1
      lines.push({ marker: raw[0], text: raw.slice(1) })
    }
  }
  return { lines, added, removed }
}

/** Reads either structured Codex `fileChange` entries or the `*** Begin Patch` grammar. */
export function patchDetails(step: Pick<ExecutionStep, 'tool' | 'toolKind' | 'input' | 'files'>) {
  if (step.files && step.files.length > 0) {
    const files: PatchFile[] = step.files.map(entry => {
      const parsed = parseUnifiedDiffLines(entry.diff)
      return {
        path: entry.path,
        kind: entry.kind === 'add' ? 'add' : entry.kind === 'delete' ? 'delete' : 'update',
        added: parsed.added,
        removed: parsed.removed,
        lines: parsed.lines
      }
    })
    return {
      files,
      added: files.reduce((sum, file) => sum + file.added, 0),
      removed: files.reduce((sum, file) => sum + file.removed, 0),
      truncated: false
    }
  }

  if (step.tool !== 'apply_patch' || typeof step.input !== 'string') return undefined
  const lines = step.input.trimStart().split(/\r?\n/)
  if (lines[0] !== '*** Begin Patch') return undefined
  const files: PatchFile[] = []
  let ended = false
  for (const line of lines.slice(1)) {
    const header = /^\*\*\* (Add|Delete|Update) File: (.+)$/.exec(line)
    const file = files.at(-1)
    if (header) {
      files.push({
        path: header[2]!,
        kind: header[1] === 'Add' ? 'add' : header[1] === 'Delete' ? 'delete' : 'update',
        added: 0,
        removed: 0,
        lines: []
      })
    } else if (line === '*** End Patch') {
      ended = true
      break
    } else if (!file || line === '*** End of File') {
      continue
    } else if (line.startsWith('*** Move to: ')) {
      file.movePath = line.slice('*** Move to: '.length)
    } else if (line.startsWith('@@')) {
      file.lines.push({ marker: '@', text: line.slice(2).trim() })
    } else if (line[0] === '+' || line[0] === '-' || line[0] === ' ') {
      if (line[0] === '+') file.added += 1
      if (line[0] === '-') file.removed += 1
      file.lines.push({ marker: line[0], text: line.slice(1) })
    }
  }
  if (!files.length) return undefined
  return {
    files,
    added: files.reduce((sum, file) => sum + file.added, 0),
    removed: files.reduce((sum, file) => sum + file.removed, 0),
    truncated: !ended
  }
}

function PatchCounts({ added, removed }: { added: number; removed: number }) {
  const { t } = useTranslation()
  if (!added && !removed) return null
  return (
    <span className="pod-chat-patch-counts">
      <span aria-hidden>
        {added > 0 && <span data-marker="+">+{added}</span>}
        {removed > 0 && <span data-marker="-">−{removed}</span>}
      </span>
      <span className="sr-only">{t('pod.chat_timeline.patch_counts', { added, removed })}</span>
    </span>
  )
}

function PatchView({ patch }: { patch: NonNullable<ReturnType<typeof patchDetails>> }) {
  const { t } = useTranslation()
  return (
    <div className="pod-chat-patch">
      {patch.files.map((file, position) => (
        <section key={position}>
          <header>
            <span className="pod-chat-patch-path">{file.movePath ? `${file.path} → ${file.movePath}` : file.path}</span>
            {file.kind !== 'update' && (
              <span className="pod-chat-patch-kind">
                {t(file.kind === 'add' ? 'pod.chat_timeline.patch_added_file' : 'pod.chat_timeline.patch_deleted_file')}
              </span>
            )}
            <PatchCounts added={file.added} removed={file.removed} />
          </header>
          {file.lines.length > 0 && (
            <pre>
              {file.lines.map((line, index) => (
                <span key={index} data-marker={line.marker}>
                  {line.marker === '@' ? `@@ ${line.text}`.trimEnd() : `${line.marker}${line.text}`}
                </span>
              ))}
            </pre>
          )}
        </section>
      ))}
      {patch.truncated && <p className="pod-chat-patch-truncated">{t('pod.chat_timeline.patch_truncated')}</p>}
    </div>
  )
}

/** A command prints its failures and summary last, so an expanded command shows the end of its output first. */
function showOutputEnd(event: SyntheticEvent<HTMLElement>) {
  if (!event.currentTarget.hasAttribute('open')) return
  for (const pre of event.currentTarget.querySelectorAll(
    '.pod-chat-command-terminal pre:not(.pod-chat-command-text)'
  )) {
    pre.scrollTop = pre.scrollHeight
  }
}

export function ToolRunView({ steps, compact = false }: { steps: ExecutionStep[]; compact?: boolean }) {
  const { t } = useTranslation()
  if (!steps.length) return null
  if (compact && steps.length > 1) {
    const runningCount = steps.filter(
      step =>
        ![
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
    ).length
    if (runningCount <= 1) {
      const latest = steps[steps.length - 1]!
      return (
        <details
          className="pod-chat-tool-group"
          open={steps.some(step => ['failed', 'error', 'stopped'].includes(step.status)) || undefined}>
          <summary>
            <ToolIcon tool={latest.tool} toolKind={latest.toolKind} />
            <span className="pod-chat-tool-title">{t('pod.chat_timeline.steps')}</span>
          </summary>
          <ToolRunView steps={steps} />
        </details>
      )
    }
  }
  return (
    <ol className="pod-chat-tool-run" aria-label={t('pod.chat_timeline.steps')}>
      {steps.map(step => {
        const failed = ['failed', 'error'].includes(step.status)
        const stopped = ['stopped', 'cancelled'].includes(step.status)
        const complete = ['completed', 'complete', 'success', 'succeeded', 'settled'].includes(step.status)
        const isSkill = skillStepName(step) !== undefined
        const terminal = isSkill ? undefined : commandDetails(step)
        const patch = isSkill || terminal ? undefined : patchDetails(step)
        const input = isSkill ? undefined : formatToolDetail(step.input)
        const output = isSkill ? undefined : formatToolDetail(step.output)
        const expandable = !isSkill && Boolean(terminal || patch || input || output)
        const Row = expandable ? 'details' : 'div'
        const Label = expandable ? 'summary' : 'div'
        const labelText = localizedStepTitle(step, t)
        return (
          <li key={step.id}>
            <Row
              className={`pod-chat-tool-step${isSkill ? ' pod-chat-tool-step-skill' : ''}`}
              data-status={failed ? 'failed' : stopped ? 'stopped' : complete ? 'completed' : 'running'}
              onToggle={terminal ? showOutputEnd : undefined}>
              <Label className="pod-chat-tool-line">
                <ToolIcon tool={step.tool} toolKind={isSkill ? 'skill' : step.toolKind} />
                <span className="pod-chat-tool-title" title={labelText}>
                  {labelText}
                </span>
                {patch && <PatchCounts added={patch.added} removed={patch.removed} />}
                <span
                  className="pod-chat-tool-state"
                  aria-label={t(
                    `pod.chat_timeline.${failed ? 'failed' : stopped ? 'stopped' : complete ? 'completed' : 'running'}`
                  )}>
                  {stopped ? (
                    <RiStopFill aria-hidden />
                  ) : failed ? (
                    <RiCloseLine aria-hidden />
                  ) : complete ? (
                    <RiCheckLine aria-hidden />
                  ) : (
                    <Spinner aria-hidden />
                  )}
                </span>
              </Label>
              {expandable &&
                (terminal ? (
                  <div className="pod-chat-command-terminal">
                    <header>
                      <RiTerminalBoxLine aria-hidden />
                      <span>{t('pod.chat_timeline.command')}</span>
                      {terminal.exitCode != null && (
                        <span className="pod-chat-command-exit" data-failed={failed || undefined}>
                          {t('pod.chat_timeline.exit_code', { code: terminal.exitCode })}
                        </span>
                      )}
                    </header>
                    <div>
                      {terminal.workdir && <p className="pod-chat-command-workdir">{terminal.workdir}</p>}
                      <pre className="pod-chat-command-text">
                        <span aria-hidden>$ </span>
                        {terminal.command}
                      </pre>
                      {terminal.stdout && <pre>{terminal.stdout}</pre>}
                      {terminal.stderr && (
                        <pre className="pod-chat-command-stderr" data-failed={failed || undefined}>
                          {terminal.stderr}
                        </pre>
                      )}
                    </div>
                  </div>
                ) : patch ? (
                  <div className="pod-chat-tool-detail">
                    <PatchView patch={patch} />
                    {output && (
                      <div>
                        <span>{t('pod.chat_timeline.output')}</span>
                        <pre>{output}</pre>
                      </div>
                    )}
                  </div>
                ) : (
                  (input || output) && (
                    <div className="pod-chat-tool-detail">
                      {input && (
                        <div>
                          <span>{t('pod.chat_timeline.input')}</span>
                          <pre>{input}</pre>
                        </div>
                      )}
                      {output && (
                        <div>
                          <span>{t('pod.chat_timeline.output')}</span>
                          <pre>{output}</pre>
                        </div>
                      )}
                    </div>
                  )
                ))}
            </Row>
          </li>
        )
      })}
    </ol>
  )
}
