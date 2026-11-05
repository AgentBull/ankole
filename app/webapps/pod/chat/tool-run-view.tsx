import {
  RiCheckLine,
  RiCloseLine,
  RiDatabase2Line,
  RiFileTextLine,
  RiLoader4Line,
  RiSearchLine,
  RiStopFill,
  RiTerminalBoxLine,
  RiToolsLine
} from '@remixicon/react'
import type { TFunction } from 'i18next'
import type { SyntheticEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { isRecord, safeJsonParse } from '@agentbull/active-support'
import { humanizeTechnicalLabel } from '../../common/humanize-technical-label'
import type { ExecutionStep } from './types'
import { formatElapsed } from './elapsed'

function ToolIcon({ tool }: { tool: string }) {
  const Icon = /bash|terminal|command|shell/.test(tool)
    ? RiTerminalBoxLine
    : /base|db\.|query/.test(tool)
      ? RiDatabase2Line
      : /brain|search|memory/.test(tool)
        ? RiSearchLine
        : /page|file|read|write/.test(tool)
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
  if (typeof parsed === 'string') return parsed.trim() ? parsed : undefined
  if (Array.isArray(parsed)) return parsed.length ? JSON.stringify(parsed, null, 2) : undefined
  if (isRecord(parsed)) return Object.keys(parsed).length ? JSON.stringify(parsed, null, 2) : undefined
  return JSON.stringify(parsed, null, 2)
}

export function humanizeToolName(tool: string): string {
  const cleaned = tool.replace(/^mcp__[^_]+__/, '').replace(/[.:/]+/g, '_')
  return humanizeTechnicalLabel(cleaned) || tool
}

/** A step reads as the localized activity label that people saw while it ran, when it has one. */
export function stepTitle(
  step: Pick<ExecutionStep, 'title' | 'tool' | 'label_key' | 'label_bindings'>,
  t: TFunction
): string {
  const fallback = step.title && step.title !== step.tool ? step.title : humanizeToolName(step.tool)
  return step.label_key ? t(step.label_key, { ...step.label_bindings, defaultValue: fallback }) : fallback
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
    workdir: typeof input.workdir === 'string' ? input.workdir : undefined,
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

/** Reads the freeform `apply_patch` grammar that the Worker and Codex share; anything else stays a plain detail. */
export function patchDetails(step: Pick<ExecutionStep, 'tool' | 'input'>) {
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
  // The work history keeps a bounded excerpt of each input, so a long patch can stop before its end marker.
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
  const { t, i18n } = useTranslation()
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
            <ToolIcon tool={latest.tool} />
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
        const terminal = commandDetails(step)
        const patch = terminal ? undefined : patchDetails(step)
        const input = formatToolDetail(step.input)
        const output = formatToolDetail(step.output)
        const Row = terminal || input || output ? 'details' : 'div'
        const Label = Row === 'details' ? 'summary' : 'div'
        const title = stepTitle(step, t)
        return (
          <li key={step.id}>
            <Row
              className="pod-chat-tool-step"
              data-status={failed ? 'failed' : stopped ? 'stopped' : complete ? 'completed' : 'running'}
              onToggle={terminal ? showOutputEnd : undefined}>
              <Label className="pod-chat-tool-line">
                <ToolIcon tool={step.tool} />
                <span className="pod-chat-tool-title" title={title}>
                  {title}
                </span>
                {patch && <PatchCounts added={patch.added} removed={patch.removed} />}
                {step.duration_ms != null && <time>{formatElapsed(step.duration_ms, i18n.language)}</time>}
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
                    <RiLoader4Line aria-hidden className="animate-spin" />
                  )}
                </span>
              </Label>
              {terminal ? (
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
              )}
            </Row>
          </li>
        )
      })}
    </ol>
  )
}
