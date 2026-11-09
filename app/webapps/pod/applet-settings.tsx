import {
  Badge,
  Button,
  Dialog,
  DialogContent,
  DialogTitle,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  toast,
  useIsMobile
} from '@ankole/uikit'
import {
  RiCloseLine,
  RiCodeSSlashLine,
  RiFileList3Line,
  RiFlashlightLine,
  RiLinksLine,
  RiSettings3Line,
  RiTerminalBoxLine
} from '@remixicon/react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import { BdiLabel } from '../common/bidi-file-name'
import { ErrorBoundary } from '../common/error-boundary'
import * as api from './api/generated/sdk.gen'
import {
  AppletAutomationTab,
  AppletFunctionsTab,
  AppletJobSelectorBar,
  AppletLogsTab,
  AppletWebhooksTab,
  useAppletJobsController
} from './applet-automation'
import { AppletMissingEnvBanner } from './applet-missing-env-banner'
import {
  appletEnvKeys,
  appletEnvsQuery,
  canEditAppletEnv,
  openAppletSettings,
  registerAppletSettingsOpener,
  resolveAppletSettingsInitialTab,
  type AppletSettingsTab,
  type OpenAppletSettingsRequest
} from './applet-settings-state'
import { contentKeys, type PageDetail } from './content-api'
import { executeEnvVarBatchImport, type EnvVarSaveInput, type ParsedDotEnvItem } from './env-vars-dotenv'
import { EnvVarsEditor } from './env-vars-editor'
import { automationJobID } from './state/connectors'

export {
  AppletMissingEnvBanner,
  appletEnvKeys,
  canEditAppletEnv,
  openAppletSettings,
  resolveAppletSettingsInitialTab,
  type AppletSettingsTab,
  type OpenAppletSettingsRequest
}

type RequestedJobSelection = {
  seq: number
  jobID: number
}

function AppletEnvironmentTab({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const pageID = detail.page.id
  const envs = useQuery(appletEnvsQuery(pageID, detail.page.revision, canEditAppletEnv(detail)))

  const refreshAfterChange = async () => {
    await Promise.all([
      client.invalidateQueries({ queryKey: appletEnvKeys.all(pageID) }),
      client.invalidateQueries({ queryKey: [...contentKeys.all, 'applet-routes', pageID] }),
      client.invalidateQueries({ queryKey: [...contentKeys.page(pageID), 'functions'] })
    ])
  }

  const putAppletEnv = (input: EnvVarSaveInput) =>
    api.podAppletEnvPut({
      path: { page_id: pageID, name: input.name },
      body: {
        data: {
          ...(input.value === undefined ? {} : { value: input.value }),
          secret: input.secret,
          description: input.description ?? null
        }
      }
    })

  const handleSave = async (input: EnvVarSaveInput) => {
    await putAppletEnv(input)
    await refreshAfterChange()
    toast.success(t('pod.env_vars.saved', { name: input.name }))
  }

  const handleImport = (entries: ParsedDotEnvItem[], secret: boolean) =>
    executeEnvVarBatchImport({
      entries,
      secret,
      putVar: putAppletEnv,
      refresh: refreshAfterChange,
      onAllSaved: saved => toast.success(t('pod.env_vars.imported_count', { count: saved.length }))
    })

  const handleDelete = async (name: string) => {
    const response = await api.podAppletEnvDelete({ path: { page_id: pageID, name } })
    await refreshAfterChange()
    toast.success(
      t(
        response.env.source === 'missing' && !response.env.declared
          ? 'pod.env_vars.deleted'
          : 'pod.env_vars.reset_done',
        { name }
      )
    )
  }

  const canDecrypt = Boolean(envs.data?.can_decrypt)

  return (
    <div className="grid gap-4">
      <header className="grid gap-1">
        <h2 className="text-base font-semibold text-foreground">{t('pod.env_vars.applet_title')}</h2>
        <p className="text-sm leading-5 text-muted-foreground">{t('pod.env_vars.applet_description')}</p>
      </header>
      <EnvVarsEditor
        items={envs.data?.envs ?? []}
        ownSource="applet"
        isLoading={envs.isLoading}
        error={envs.error}
        canDecrypt={canDecrypt}
        onRetry={() => void envs.refetch()}
        onSave={handleSave}
        onImport={handleImport}
        onDelete={handleDelete}
        onDecrypt={
          canDecrypt
            ? async name => {
                const response = await api.podAppletEnvDecrypt({ path: { page_id: pageID, name } })
                return response.decrypted_value.value
              }
            : undefined
        }
      />
    </div>
  )
}

export function AppletSettingsDialog({
  detail,
  open,
  onOpenChange,
  tab,
  onTabChange,
  requestedJobSelection
}: {
  detail: PageDetail
  open: boolean
  onOpenChange: (open: boolean) => void
  tab: AppletSettingsTab
  onTabChange: (tab: AppletSettingsTab) => void
  requestedJobSelection?: RequestedJobSelection
}) {
  const { t } = useTranslation()
  const isMobile = useIsMobile()
  const envBadgeDescId = useId()
  const canEdit = canEditAppletEnv(detail)
  const canCreateJob = !detail.page.deleted_at && detail.actions.includes('node_contribute')
  const activeTab: AppletSettingsTab = tab === 'environment' && !canEdit ? 'automation' : tab

  const [visitedState, setVisitedState] = useState<{
    open: boolean
    pageID: string
    tabs: ReadonlySet<AppletSettingsTab>
  }>(() => ({
    open,
    pageID: detail.page.id,
    tabs: open ? new Set([activeTab]) : new Set()
  }))

  let visitedTabs = visitedState.tabs
  if (visitedState.open !== open || visitedState.pageID !== detail.page.id) {
    visitedTabs = open ? new Set([activeTab]) : new Set()
    setVisitedState({ open, pageID: detail.page.id, tabs: visitedTabs })
  } else if (open && !visitedState.tabs.has(activeTab)) {
    visitedTabs = new Set(visitedState.tabs).add(activeTab)
    setVisitedState({ open, pageID: detail.page.id, tabs: visitedTabs })
  }

  const envs = useQuery(appletEnvsQuery(detail.page.id, detail.page.revision, open && canEdit))
  const missingCount = envs.data?.envs.filter(item => item.required && !item.present).length ?? 0

  const jobsEnabled = open && (visitedTabs.has('automation') || visitedTabs.has('webhooks') || visitedTabs.has('logs'))
  const jobsController = useAppletJobsController(detail, jobsEnabled)
  // The Job tabs share one selector, so the dialog renders their headings above it.
  const jobTabHeader =
    activeTab === 'automation'
      ? { title: t('pod.automation.title'), description: t('pod.automation.description') }
      : activeTab === 'webhooks'
        ? { title: t('pod.applet_settings.tab_webhooks'), description: t('pod.applet_settings.webhooks_description') }
        : activeTab === 'logs'
          ? { title: t('pod.applet_settings.tab_logs'), description: t('pod.applet_settings.logs_description') }
          : null

  useEffect(() => {
    if (requestedJobSelection !== undefined) {
      jobsController.setSelectedJobID(requestedJobSelection.jobID)
    }
  }, [requestedJobSelection?.seq, requestedJobSelection?.jobID, jobsController.setSelectedJobID])

  const switchTab = (next: string) => {
    onTabChange(next as AppletSettingsTab)
  }

  const navigationItems: Array<{
    value: AppletSettingsTab
    label: string
    icon: ReactNode
    badgeCount?: number
  }> = [
    ...(canEdit
      ? [
          {
            value: 'environment' as const,
            label: t('pod.applet_settings.tab_environment'),
            icon: <RiTerminalBoxLine aria-hidden className="size-4" />,
            badgeCount: missingCount
          }
        ]
      : []),
    {
      value: 'automation',
      label: t('pod.applet_settings.tab_automation'),
      icon: <RiFlashlightLine aria-hidden className="size-4" />
    },
    {
      value: 'webhooks',
      label: t('pod.applet_settings.tab_webhooks'),
      icon: <RiLinksLine aria-hidden className="size-4" />
    },
    {
      value: 'logs',
      label: t('pod.applet_settings.tab_logs'),
      icon: <RiFileList3Line aria-hidden className="size-4" />
    },
    {
      value: 'functions',
      label: t('pod.applet_settings.tab_functions'),
      icon: <RiCodeSSlashLine aria-hidden className="size-4" />
    }
  ]

  const pageTitle = detail.page.title || detail.page.name || t('pod.content.untitled')

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        className="pod-applet-settings-dialog flex h-[min(780px,calc(100dvh-2rem))] w-[min(1040px,calc(100vw-2rem))] max-w-none sm:max-w-none flex-col gap-0 overflow-hidden overscroll-contain p-0"
        showCloseButton={false}>
        <header className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-5 py-3.5">
          <div className="flex min-w-0 items-center gap-2.5">
            <RiSettings3Line aria-hidden className="size-4 shrink-0 text-muted-foreground" />
            <DialogTitle className="p-0!">{t('pod.applet_settings.title')}</DialogTitle>
            <span aria-hidden className="text-muted-foreground">
              ·
            </span>
            <span className="truncate text-sm text-muted-foreground">
              <BdiLabel value={pageTitle} />
            </span>
          </div>
          <Button
            type="button"
            size="icon-sm"
            variant="ghost"
            aria-label={t('common.close')}
            onClick={() => onOpenChange(false)}>
            <RiCloseLine aria-hidden />
          </Button>
        </header>

        {missingCount > 0 && canEdit ? (
          <span id={envBadgeDescId} className="sr-only">
            {t('pod.applet_settings.missing_env_badge_sr', { count: missingCount })}
          </span>
        ) : null}

        {open && (
          <Tabs
            orientation={isMobile ? 'horizontal' : 'vertical'}
            value={activeTab}
            onValueChange={switchTab}
            className="flex min-h-0 flex-1 flex-col gap-0 md:flex-row">
            <aside className="shrink-0 border-b border-border bg-muted/20 px-3 py-2 md:w-52 md:border-r md:border-b-0 md:p-3">
              <TabsList
                variant="object"
                aria-label={t('pod.applet_settings.navigation')}
                className="w-full min-w-0 justify-start gap-1 overflow-x-auto group-data-horizontal/tabs:h-auto md:flex-col md:items-stretch md:overflow-visible">
                {navigationItems.map(item => (
                  <TabsTrigger
                    key={item.value}
                    value={item.value}
                    aria-describedby={
                      item.value === 'environment' && (item.badgeCount ?? 0) > 0 ? envBadgeDescId : undefined
                    }
                    className="min-h-9 shrink-0 justify-start gap-2.5 rounded-lg px-3 py-1.5 text-sm md:w-full">
                    {item.icon}
                    <span className="truncate">{item.label}</span>
                    {(item.badgeCount ?? 0) > 0 ? (
                      <Badge variant="warning" aria-hidden className="ml-auto tabular-nums">
                        {item.badgeCount}
                      </Badge>
                    ) : null}
                  </TabsTrigger>
                ))}
              </TabsList>
            </aside>

            <div className="min-h-0 min-w-0 flex-1 overflow-y-auto overscroll-contain px-5 py-5 sm:px-7 sm:py-6">
              {canEdit && (
                <TabsContent value="environment" keepMounted className="outline-none [&[hidden]]:hidden">
                  {visitedTabs.has('environment') ? (
                    <ErrorBoundary variant="panel" resetKeys={[detail.page.id]}>
                      <AppletEnvironmentTab key={detail.page.id} detail={detail} />
                    </ErrorBoundary>
                  ) : null}
                </TabsContent>
              )}
              <div hidden={!jobTabHeader} className="mb-5 grid gap-5 [&[hidden]]:hidden">
                {jobTabHeader ? (
                  <header className="grid gap-1">
                    <h2 className="text-base font-semibold text-foreground">{jobTabHeader.title}</h2>
                    <p className="text-sm text-muted-foreground">{jobTabHeader.description}</p>
                  </header>
                ) : null}
                <AppletJobSelectorBar controller={jobsController} isActive={Boolean(jobTabHeader)} />
              </div>
              <TabsContent value="automation" keepMounted className="outline-none [&[hidden]]:hidden">
                {visitedTabs.has('automation') ? (
                  <ErrorBoundary variant="panel" resetKeys={[detail.page.id]}>
                    <AppletAutomationTab
                      controller={jobsController}
                      isActive={activeTab === 'automation'}
                      onOpenLogs={() => switchTab('logs')}
                    />
                  </ErrorBoundary>
                ) : null}
              </TabsContent>
              <TabsContent value="webhooks" keepMounted className="outline-none [&[hidden]]:hidden">
                {visitedTabs.has('webhooks') ? (
                  <ErrorBoundary variant="panel" resetKeys={[detail.page.id]}>
                    <AppletWebhooksTab
                      controller={jobsController}
                      isActive={activeTab === 'webhooks'}
                      onOpenLogs={() => switchTab('logs')}
                    />
                  </ErrorBoundary>
                ) : null}
              </TabsContent>
              <TabsContent value="logs" keepMounted className="outline-none [&[hidden]]:hidden">
                {visitedTabs.has('logs') ? (
                  <ErrorBoundary variant="panel" resetKeys={[detail.page.id]}>
                    <AppletLogsTab controller={jobsController} isActive={activeTab === 'logs'} />
                  </ErrorBoundary>
                ) : null}
              </TabsContent>
              <TabsContent value="functions" keepMounted className="outline-none [&[hidden]]:hidden">
                {visitedTabs.has('functions') ? (
                  <ErrorBoundary variant="panel" resetKeys={[detail.page.id]}>
                    <AppletFunctionsTab
                      detail={detail}
                      canCreateJob={canCreateJob && !jobsController.createJob.isPending}
                      onCreateJobForAction={actionKey =>
                        jobsController.startCreateWithAction(actionKey, () => switchTab('automation'))
                      }
                    />
                  </ErrorBoundary>
                ) : null}
              </TabsContent>
            </div>
          </Tabs>
        )}
      </DialogContent>
    </Dialog>
  )
}

/** Unified Applet settings entry in the Page top bar; also opens directly to Automation when a URL names a Job. */
export function AppletSettingsControl({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const badgeDescId = useId()
  const pageID = detail.page.id
  const canEdit = canEditAppletEnv(detail)
  const requestSeqRef = useRef(0)
  const initialUrlJobID =
    typeof window === 'undefined' ? undefined : automationJobID(new URLSearchParams(window.location.search))

  const [open, setOpen] = useState(initialUrlJobID !== undefined)
  const [hasChosenTab, setHasChosenTab] = useState(initialUrlJobID !== undefined)
  const [requestedJobSelection, setRequestedJobSelection] = useState<RequestedJobSelection | undefined>(() =>
    initialUrlJobID === undefined ? undefined : { seq: 0, jobID: initialUrlJobID }
  )
  const [tab, setTab] = useState<AppletSettingsTab>(() =>
    resolveAppletSettingsInitialTab({
      canEdit,
      hasAutomationLink: initialUrlJobID !== undefined
    })
  )

  useEffect(
    () =>
      registerAppletSettingsOpener(pageID, request => {
        setTab(
          resolveAppletSettingsInitialTab({
            canEdit: canEditAppletEnv(detail),
            hasAutomationLink: request.jobID !== undefined,
            requestedTab: request.tab
          })
        )
        if (request.jobID !== undefined) {
          requestSeqRef.current += 1
          setRequestedJobSelection({ seq: requestSeqRef.current, jobID: request.jobID })
        } else {
          setRequestedJobSelection(undefined)
        }
        setHasChosenTab(true)
        setOpen(true)
      }),
    [pageID, detail]
  )

  const envs = useQuery(appletEnvsQuery(pageID, detail.page.revision, canEdit))
  const missingCount = envs.data?.envs.filter(item => item.required && !item.present).length ?? 0

  return (
    <>
      {missingCount > 0 ? (
        <span id={badgeDescId} className="sr-only">
          {t('pod.applet_settings.missing_env_badge_sr', { count: missingCount })}
        </span>
      ) : null}
      <Button
        variant="ghost"
        size="sm"
        title={t('pod.applet_settings.button')}
        aria-describedby={missingCount > 0 ? badgeDescId : undefined}
        onClick={() => {
          if (!hasChosenTab) {
            setTab(
              resolveAppletSettingsInitialTab({
                canEdit,
                hasAutomationLink: false
              })
            )
            setHasChosenTab(true)
          }
          setRequestedJobSelection(undefined)
          setOpen(true)
        }}>
        <RiSettings3Line aria-hidden className="size-4" />
        <span className="@max-[640px]:sr-only">{t('pod.applet_settings.button')}</span>
        {missingCount > 0 ? (
          <Badge variant="warning" aria-hidden className="tabular-nums">
            {missingCount}
          </Badge>
        ) : null}
      </Button>
      {open ? (
        <AppletSettingsDialog
          key={pageID}
          detail={detail}
          open={open}
          onOpenChange={setOpen}
          tab={tab}
          onTabChange={nextTab => {
            setHasChosenTab(true)
            setTab(nextTab)
          }}
          requestedJobSelection={requestedJobSelection}
        />
      ) : null}
    </>
  )
}
