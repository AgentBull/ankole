import { Link, useConsoleTenant } from './tenant-context'

import { Button, Tooltip, TooltipContent, TooltipTrigger, cn } from '@ankole/uikit'
import { RiArrowLeftLine, RiRefreshLine } from '@remixicon/react'
import { useQueryClient } from '@tanstack/react-query'
import { useState, type ComponentProps, type ReactNode } from 'react'
import { Helmet } from 'react-helmet-async'
import { useTranslation } from 'react-i18next'

import { linkTarget } from '../common/router'
import { ConsoleReadiness } from './console-readiness'

/**
 * Names the browser tab and history entry after the page. The Phoenix shell
 * serves a fixed "Ankole Console" title; each routed page appends its own name
 * so tabs and history stay distinguishable.
 */
export function DocumentTitle({ title }: { title: string }) {
  return (
    <Helmet>
      <title>{`${title} · Ankole Console`}</title>
    </Helmet>
  )
}

/** One page-level vertical rhythm for list, editor, detail, and dashboard routes. */
export function PageStack({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div {...props} className={cn('grid w-full min-w-0 grid-cols-[minmax(0,1fr)] gap-5 [&>*]:min-w-0', className)} />
  )
}

/** Muted back link rendered above editor and detail page headers. A real link, so it keeps middle-click and new-tab. */
export function BackLink({ label, to }: { label?: string; to: string }) {
  const { t } = useTranslation()
  return (
    <Link
      {...linkTarget(to)}
      className="inline-flex w-fit items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground">
      <RiArrowLeftLine className="size-4" aria-hidden />
      {label ?? t('common.back')}
    </Link>
  )
}

export function PageHeader({
  actions,
  description,
  title
}: {
  actions?: ReactNode
  description?: string
  title: string
}) {
  const tenant = useConsoleTenant()
  return (
    <div className="flex min-w-0 flex-wrap items-end justify-between gap-4 border-b border-border pb-5">
      <DocumentTitle title={title} />
      <div className="grid min-w-0 gap-1">
        {!tenant || tenant.first ? <h2 className="title-page text-foreground">{title}</h2> : null}
        {description && (!tenant || tenant.first) ? (
          <p className="max-w-3xl text-sm leading-6 text-muted-foreground">{description}</p>
        ) : null}
        {tenant ? (
          <h3 className="title-inline">
            {tenant.display_name} <span className="text-sm font-normal text-muted-foreground">({tenant.slug})</span>
          </h3>
        ) : null}
      </div>
      {actions || tenant ? (
        <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto">
          {tenant ? <ConsoleReadiness /> : null}
          {actions}
        </div>
      ) : null}
    </div>
  )
}

export function RefreshButton() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)
  const refreshLabel = t(refreshing ? 'console.aria.refreshing' : 'console.aria.refresh')

  const refresh = () => {
    setRefreshing(true)
    void queryClient.refetchQueries({ type: 'active' }).finally(() => setRefreshing(false))
  }

  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <Button
            aria-busy={refreshing}
            aria-label={refreshLabel}
            disabled={refreshing}
            size="icon-sm"
            type="button"
            variant="outline"
          />
        }
        onClick={refresh}>
        <RiRefreshLine className={cn(refreshing && 'animate-spin')} />
      </TooltipTrigger>
      <TooltipContent>{refreshLabel}</TooltipContent>
    </Tooltip>
  )
}
