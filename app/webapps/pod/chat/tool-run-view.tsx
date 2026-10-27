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
import { useTranslation } from 'react-i18next'
import { isRecord } from '@agentbull/active-support'
import { humanizeTechnicalLabel } from '../../common/humanize-technical-label'
import type { ExecutionStep } from './types'

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
  try {
    return JSON.parse(value)
  } catch {
    return value
  }
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

export function stepTitle(step: Pick<ExecutionStep, 'title' | 'tool'>): string {
  return step.title && step.title !== step.tool ? step.title : humanizeToolName(step.tool)
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
            <ToolIcon tool={latest.tool} />
            <span className="pod-chat-tool-title">{t('pod.chat_timeline.tool_count', { count: steps.length })}</span>
          </summary>
          <ToolRunView steps={steps} />
        </details>
      )
    }
  }
  return (
    <ol className="pod-chat-tool-run" aria-label={t('pod.chat_timeline.tools')}>
      {steps.map(step => {
        const failed = ['failed', 'error'].includes(step.status)
        const stopped = ['stopped', 'cancelled'].includes(step.status)
        const complete = ['completed', 'complete', 'success', 'succeeded', 'settled'].includes(step.status)
        const terminal = commandDetails(step)
        const input = formatToolDetail(step.input)
        const output = formatToolDetail(step.output)
        const Row = terminal || input || output ? 'details' : 'div'
        const Label = Row === 'details' ? 'summary' : 'div'
        return (
          <li key={step.id}>
            <Row
              className="pod-chat-tool-step"
              data-status={failed ? 'failed' : stopped ? 'stopped' : complete ? 'completed' : 'running'}>
              <Label className="pod-chat-tool-line">
                <ToolIcon tool={step.tool} />
                <span className="pod-chat-tool-title">{stepTitle(step)}</span>
                {step.duration_ms != null && <time>{(step.duration_ms / 1000).toFixed(1)}s</time>}
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
