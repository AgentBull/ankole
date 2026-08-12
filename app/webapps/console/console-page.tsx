import { Button, Tooltip, TooltipContent, TooltipTrigger, cn } from '@ankole/uikit'
import { RiArrowLeftLine, RiRefreshLine } from '@remixicon/react'
import { useQueryClient } from '@tanstack/react-query'
import { useState, type ComponentProps, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'

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
      to={to}
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
  return (
    <div className="flex min-w-0 flex-wrap items-end justify-between gap-4 border-b border-border pb-5">
      <div className="grid min-w-0 gap-1">
        <h2 className="text-2xl font-semibold tracking-normal text-foreground">{title}</h2>
        {description ? <p className="max-w-3xl text-sm leading-6 text-muted-foreground">{description}</p> : null}
      </div>
      {actions ? <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto">{actions}</div> : null}
    </div>
  )
}

/** Refetches every active page query and reports progress on the initiating control. */
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
