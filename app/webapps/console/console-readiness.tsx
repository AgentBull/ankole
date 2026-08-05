import {
  Button,
  Popover,
  PopoverContent,
  PopoverDescription,
  PopoverTitle,
  PopoverTrigger,
  Progress,
  ProgressLabel,
  ProgressValue,
  Skeleton,
  cn
} from '@ankole/uikit'
import {
  RiArrowRightSLine,
  RiCheckboxBlankCircleLine,
  RiCheckboxCircleLine,
  RiErrorWarningLine,
  RiListCheck3
} from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import { ankoleWebConsoleReadinessControllerShowOptions } from './api/generated/@tanstack/react-query.gen'
import type { ConsoleReadinessResponse } from './api/generated/types.gen'

const AUTO_OPEN_STORAGE_KEY = 'ankole.console.readiness.seen.v1'

export function ConsoleReadiness() {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const query = useQuery({
    ...ankoleWebConsoleReadinessControllerShowOptions(),
    refetchInterval: open ? 2_000 : 30_000,
    refetchOnReconnect: 'always',
    refetchOnWindowFocus: 'always'
  })
  const readiness = query.data

  useEffect(() => {
    if (!readiness || readiness.ready) return

    try {
      if (window.localStorage.getItem(AUTO_OPEN_STORAGE_KEY)) return
      window.localStorage.setItem(AUTO_OPEN_STORAGE_KEY, 'true')
      setOpen(true)
    } catch {
      // Readiness remains available through the trigger when browser storage is unavailable.
    }
  }, [readiness])

  const changeOpen = (nextOpen: boolean) => {
    setOpen(nextOpen)
    if (!nextOpen) return
    void query.refetch()

    try {
      window.localStorage.setItem(AUTO_OPEN_STORAGE_KEY, 'true')
    } catch {
      // Opening the readiness popover does not depend on browser storage.
    }
  }

  const completed = readiness?.completed_core_steps
  const total = readiness?.total_core_steps
  const triggerLabel = query.isError
    ? t('console.readiness.trigger_unavailable')
    : completed === undefined || total === undefined
      ? t('console.readiness.trigger_loading')
      : t('console.readiness.trigger', { completed, total })

  return (
    <Popover open={open} onOpenChange={changeOpen}>
      <PopoverTrigger
        render={<Button aria-label={triggerLabel} size="sm" type="button" variant="ghost" className="px-2 sm:px-3" />}>
        {query.isError ? (
          <RiErrorWarningLine className="text-destructive" aria-hidden />
        ) : readiness?.ready ? (
          <RiCheckboxCircleLine className="text-success" aria-hidden />
        ) : (
          <RiListCheck3 aria-hidden />
        )}
        <span className="hidden normal-case sm:inline">{t('console.readiness.trigger_short')}</span>
        {query.isError ? (
          <span aria-hidden>—</span>
        ) : completed === undefined || total === undefined ? (
          <span aria-hidden>…</span>
        ) : (
          <span className="tabular-nums" aria-hidden>
            {completed}/{total}
          </span>
        )}
      </PopoverTrigger>
      <PopoverContent
        align="end"
        side="bottom"
        sideOffset={8}
        className="w-[calc(100vw-2rem)] max-w-sm gap-0 overflow-hidden p-0">
        <header className="border-b border-border p-4">
          <div className="flex items-center justify-between gap-3">
            <PopoverTitle>{t('console.readiness.title')}</PopoverTitle>
            {readiness ? (
              <span className="shrink-0 text-xs text-muted-foreground tabular-nums">
                {readiness.completed_core_steps}/{readiness.total_core_steps}
              </span>
            ) : null}
          </div>
          <PopoverDescription className="line-clamp-2 text-pretty text-xs leading-5">
            {readiness?.ready ? t('console.readiness.ready_description') : t('console.readiness.description')}
          </PopoverDescription>
          {readiness ? (
            <Progress
              value={readiness.completed_core_steps}
              max={readiness.total_core_steps}
              className="mt-3 gap-1.5"
              aria-label={triggerLabel}>
              <ProgressLabel className="text-xs">{t('console.readiness.core_configuration')}</ProgressLabel>
              <ProgressValue className="sr-only">
                {() => `${readiness.completed_core_steps}/${readiness.total_core_steps}`}
              </ProgressValue>
            </Progress>
          ) : null}
        </header>

        <div className="max-h-[70dvh] overflow-y-auto" aria-live="polite">
          {query.isPending ? (
            <div className="grid gap-2 p-4" aria-label={t('common.loading')}>
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
            </div>
          ) : query.isError || !readiness ? (
            <div className="flex gap-3 p-4 text-sm text-destructive" role="alert">
              <RiErrorWarningLine className="mt-0.5 size-4 shrink-0" aria-hidden />
              <p>{t('console.readiness.unavailable')}</p>
            </div>
          ) : (
            <ReadinessContent readiness={readiness} close={() => setOpen(false)} />
          )}
        </div>
      </PopoverContent>
    </Popover>
  )
}

function ReadinessContent({ readiness, close }: { readiness: ConsoleReadinessResponse; close: () => void }) {
  const { t } = useTranslation()
  const providerID = readiness.provider.provider_id
  const agentUID = readiness.agent.uid
  const profileAgentUID = readiness.model_profiles.agent_uid
  const signalAgentUID = readiness.signal_route.agent_uid

  const coreSteps = [
    {
      complete: readiness.provider.complete,
      detail: readiness.provider.complete
        ? t('console.readiness.provider_complete', { id: providerID })
        : t('console.readiness.provider_incomplete'),
      title: t('console.readiness.provider_title'),
      to: providerID ? `/providers/${encodeURIComponent(providerID)}` : '/providers/new'
    },
    {
      complete: readiness.agent.complete,
      detail: readiness.agent.complete
        ? t('console.readiness.agent_complete', { name: readiness.agent.display_name ?? agentUID })
        : agentUID
          ? t('console.readiness.agent_needs_details')
          : t('console.readiness.agent_incomplete'),
      title: t('console.readiness.agent_title'),
      to: agentUID ? `/agents/${encodeURIComponent(agentUID)}` : '/agents/new'
    },
    {
      complete: readiness.model_profiles.complete,
      detail: readiness.model_profiles.complete
        ? t('console.readiness.profiles_complete')
        : profileAgentUID
          ? t('console.readiness.profiles_incomplete', {
              profiles: readiness.model_profiles.missing_profiles.join(', ')
            })
          : t('console.readiness.profiles_no_agent'),
      title: t('console.readiness.profiles_title'),
      to: profileAgentUID ? `/agents/${encodeURIComponent(profileAgentUID)}#model-profiles` : '/agents'
    },
    {
      complete: readiness.worker.complete,
      detail: readiness.worker.complete
        ? t('console.readiness.worker_complete', { count: readiness.worker.ready_count })
        : t('console.readiness.worker_incomplete'),
      title: t('console.readiness.worker_title'),
      to: '/workers'
    }
  ]

  return (
    <>
      <ul className="divide-y divide-border">
        {coreSteps.map(step => (
          <ReadinessRow key={step.title} {...step} onNavigate={close} />
        ))}
      </ul>
      <div className="border-t border-border">
        <h3 className="px-4 pt-3 pb-1 text-xs font-semibold text-muted-foreground">
          {t('console.readiness.recommended')}
        </h3>
        <ul>
          <ReadinessRow
            complete={readiness.signal_route.complete}
            detail={
              readiness.signal_route.complete
                ? t('console.readiness.signal_complete')
                : t('console.readiness.signal_incomplete')
            }
            title={t('console.readiness.signal_title')}
            to={signalAgentUID ? `/signals/new?agent=${encodeURIComponent(signalAgentUID)}` : '/signals'}
            onNavigate={close}
          />
        </ul>
      </div>
    </>
  )
}

function ReadinessRow({
  complete,
  detail,
  onNavigate,
  title,
  to
}: {
  complete: boolean
  detail: string
  onNavigate: () => void
  title: string
  to: string
}) {
  const { t } = useTranslation()
  const StatusIcon = complete ? RiCheckboxCircleLine : RiCheckboxBlankCircleLine

  return (
    <li>
      <Link
        to={to}
        onClick={onNavigate}
        className={cn(
          'flex min-h-12 gap-2.5 px-4 outline-none hover:bg-muted focus-visible:bg-muted focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring/30',
          complete ? 'items-center py-2' : 'items-start py-2.5'
        )}>
        <StatusIcon
          className={cn('size-4 shrink-0', complete ? 'text-success' : 'mt-0.5 text-muted-foreground')}
          aria-hidden
        />
        <span className="min-w-0 flex-1">
          <span className="block text-sm leading-5 font-medium text-foreground">{title}</span>
          {!complete ? (
            <span className="mt-0.5 block text-pretty text-xs leading-4 text-muted-foreground">{detail}</span>
          ) : null}
          <span className="sr-only">
            {complete ? t('console.readiness.complete') : t('console.readiness.incomplete')}
          </span>
        </span>
        <RiArrowRightSLine
          className={cn('size-4 shrink-0 text-muted-foreground', complete ? null : 'mt-0.5')}
          aria-hidden
        />
      </Link>
    </li>
  )
}
