import { Button, buttonVariants, cn } from '@ankole/uikit'
import { RiCheckLine, RiErrorWarningLine, RiFileCopyLine, RiRefreshLine } from '@remixicon/react'
import { QueryErrorResetBoundary } from '@tanstack/react-query'
import { Component, Fragment, useEffect, useRef, useState, type ReactNode } from 'react'
import type { RootOptions } from 'react-dom/client'
import { useTranslation } from 'react-i18next'
import { BrandIcon } from './brand'
import { requestErrorMessage } from './request-errors'

export type ErrorBoundaryVariant = 'inline' | 'panel' | 'shell'

interface ErrorFallbackRenderProps {
  error: unknown
  reset: () => void
}

/**
 * Root-level React 19 error hooks shared by every `createRoot` call so caught
 * and uncaught render failures preserve their component stack in browser logs.
 */
export const rootErrorOptions: RootOptions = {
  onCaughtError(error, errorInfo) {
    console.error('[Ankole] Caught render error', error, errorInfo.componentStack ?? '')
  },
  onUncaughtError(error, errorInfo) {
    console.error('[Ankole] Uncaught render error', error, errorInfo.componentStack ?? '')
  }
}

export function ErrorFallback({
  actions,
  className,
  error,
  label,
  reset,
  variant = 'panel'
}: {
  actions?: ReactNode
  className?: string
  error: unknown
  label?: string
  reset: () => void
  variant?: ErrorBoundaryVariant
}) {
  const { t } = useTranslation()
  const detail = diagnosticSummary(error)

  if (variant === 'inline') {
    return (
      <div
        role="alert"
        data-error-boundary="inline"
        className={cn(
          'flex min-w-0 flex-wrap items-center justify-between gap-2 rounded-control border border-border bg-muted/30 px-3 py-2 text-xs text-fg-secondary',
          className
        )}>
        <span className="flex min-w-0 items-center gap-2">
          <RiErrorWarningLine aria-hidden className="size-3.5 shrink-0 text-fg-tertiary" />
          <span className="min-w-0 break-words">
            {label ? t('common.render_error_inline', { name: label }) : t('common.render_error_inline_generic')}
          </span>
        </span>
        <span className="flex shrink-0 items-center gap-1">
          {actions}
          {detail ? <CopyDiagnosticButton copyText={diagnosticCopyText(error, detail)} /> : null}
          <Button type="button" size="xs" variant="ghost" onClick={reset}>
            {t('common.retry')}
          </Button>
        </span>
      </div>
    )
  }

  if (variant === 'shell') {
    return (
      <main
        data-error-boundary="shell"
        className={cn('grid min-h-svh place-items-center bg-ground p-6 text-foreground', className)}>
        <div
          role="alert"
          className="grid w-full max-w-lg gap-4 rounded-panel border border-border bg-card p-6 shadow-sm">
          <div className="flex items-center gap-2.5">
            <BrandIcon className="size-6 shrink-0" />
            <h1 className="text-base font-semibold leading-6">{t('common.app_error_title')}</h1>
          </div>
          <p className="text-sm leading-6 text-fg-secondary">{t('common.app_error_description')}</p>
          {detail ? <DiagnosticLine detail={detail} copyText={diagnosticCopyText(error, detail)} /> : null}
          <div className="flex flex-wrap items-center gap-2 pt-1">
            {actions}
            <Button type="button" size="sm" onClick={reset}>
              <RiRefreshLine aria-hidden />
              {t('common.retry')}
            </Button>
            <Button type="button" size="sm" variant="outline" onClick={() => window.location.reload()}>
              {t('common.reload_page')}
            </Button>
            <a href="/" className={buttonVariants({ size: 'sm', variant: 'ghost' })}>
              {t('common.back_home')}
            </a>
          </div>
        </div>
      </main>
    )
  }

  return (
    <div
      role="alert"
      data-error-boundary="panel"
      className={cn('grid min-w-0 gap-3 border border-border bg-card p-5 text-sm text-foreground', className)}>
      <div className="flex min-w-0 items-start gap-2.5">
        <RiErrorWarningLine aria-hidden className="mt-0.5 size-4 shrink-0 text-fg-secondary" />
        <div className="grid min-w-0 gap-1">
          <p className="font-semibold leading-5">
            {label ? t('common.render_error_inline', { name: label }) : t('common.render_error_title')}
          </p>
          <p className="text-xs leading-5 text-fg-secondary">{t('common.render_error_description')}</p>
        </div>
      </div>
      {detail ? <DiagnosticLine detail={detail} copyText={diagnosticCopyText(error, detail)} /> : null}
      <div className="flex flex-wrap items-center gap-2">
        {actions}
        <Button type="button" size="sm" variant="outline" onClick={reset}>
          <RiRefreshLine aria-hidden />
          {t('common.reload_section')}
        </Button>
      </div>
    </div>
  )
}

function CopyDiagnosticButton({ copyText }: { copyText: string }) {
  const { t } = useTranslation()
  const [copied, setCopied] = useState(false)
  const copiedTimer = useRef<number | null>(null)

  useEffect(
    () => () => {
      if (copiedTimer.current !== null) {
        window.clearTimeout(copiedTimer.current)
      }
    },
    []
  )

  const copy = () => {
    void navigator.clipboard
      ?.writeText(copyText)
      .then(() => {
        if (copiedTimer.current !== null) {
          window.clearTimeout(copiedTimer.current)
        }
        setCopied(true)
        copiedTimer.current = window.setTimeout(() => {
          copiedTimer.current = null
          setCopied(false)
        }, 1800)
      })
      .catch(() => {})
  }

  return (
    <Button
      type="button"
      size="icon-xs"
      variant="ghost"
      aria-label={copied ? t('common.copied') : t('common.copy_diagnostic')}
      title={copied ? t('common.copied') : t('common.copy_diagnostic')}
      onClick={copy}>
      {copied ? <RiCheckLine aria-hidden className="size-3.5" /> : <RiFileCopyLine aria-hidden className="size-3.5" />}
    </Button>
  )
}

function DiagnosticLine({ copyText, detail }: { copyText: string; detail: string }) {
  return (
    <div className="flex min-w-0 items-center justify-between gap-2 rounded-control border border-border/70 bg-muted/30 px-2.5 py-1.5">
      <code className="min-w-0 flex-1 truncate font-mono text-xs text-fg-tertiary" title={detail}>
        {detail}
      </code>
      <CopyDiagnosticButton copyText={copyText} />
    </div>
  )
}

interface ErrorBoundaryProps {
  actions?: ReactNode | ((props: ErrorFallbackRenderProps) => ReactNode)
  children: ReactNode
  className?: string
  fallback?: ReactNode | ((props: ErrorFallbackRenderProps) => ReactNode)
  label?: string
  onReset?: () => void
  resetKeys?: readonly unknown[]
  variant?: ErrorBoundaryVariant
}

export function ErrorBoundary(props: ErrorBoundaryProps) {
  return (
    <QueryErrorResetBoundary>
      {({ reset }) => <InnerErrorBoundary {...props} onResetQueries={reset} />}
    </QueryErrorResetBoundary>
  )
}

interface InnerProps extends ErrorBoundaryProps {
  onResetQueries: () => void
}

interface InnerState {
  error: unknown
  hasError: boolean
  resetCount: number
}

class InnerErrorBoundary extends Component<InnerProps, InnerState> {
  override state: InnerState = {
    error: undefined,
    hasError: false,
    resetCount: 0
  }

  static getDerivedStateFromError(error: unknown): Partial<InnerState> {
    return { error, hasError: true }
  }

  override componentDidUpdate(prevProps: InnerProps) {
    if (this.state.hasError && !areResetKeysEqual(prevProps.resetKeys, this.props.resetKeys)) {
      this.clearError()
    }
  }

  clearError = () => {
    this.props.onResetQueries()
    this.setState(current => ({
      error: undefined,
      hasError: false,
      resetCount: current.resetCount + 1
    }))
  }

  reset = () => {
    this.props.onReset?.()
    this.clearError()
  }

  override render() {
    if (!this.state.hasError) {
      return <Fragment key={this.state.resetCount}>{this.props.children}</Fragment>
    }

    const renderProps: ErrorFallbackRenderProps = {
      error: this.state.error,
      reset: this.reset
    }

    if (this.props.fallback !== undefined) {
      return typeof this.props.fallback === 'function' ? this.props.fallback(renderProps) : this.props.fallback
    }

    const resolvedActions =
      typeof this.props.actions === 'function' ? this.props.actions(renderProps) : this.props.actions

    return (
      <ErrorFallback
        actions={resolvedActions}
        className={this.props.className}
        error={this.state.error}
        label={this.props.label}
        reset={this.reset}
        variant={this.props.variant}
      />
    )
  }
}

function areResetKeysEqual(a: readonly unknown[] = [], b: readonly unknown[] = []): boolean {
  if (a.length !== b.length) return false
  for (let index = 0; index < a.length; index += 1) {
    if (!Object.is(a[index], b[index])) return false
  }
  return true
}

function diagnosticSummary(error: unknown): string {
  if (error instanceof Response) {
    return `${error.status} ${error.statusText}`.trim()
  }
  if (error instanceof Error) {
    const firstLine = error.message.split(/\r?\n/, 1)[0]?.trim() || error.name
    return firstLine.length <= 240 ? firstLine : `${firstLine.slice(0, 240)}…`
  }
  if (typeof error === 'string') {
    const firstLine = error.split(/\r?\n/, 1)[0]?.trim() ?? ''
    return firstLine.length <= 240 ? firstLine : `${firstLine.slice(0, 240)}…`
  }
  if (error != null) {
    return requestErrorMessage(error)
  }
  return ''
}

function diagnosticCopyText(error: unknown, summary: string): string {
  if (error instanceof Error && error.message.trim()) {
    return `${error.name}: ${error.message.trim()}`
  }
  return summary
}
