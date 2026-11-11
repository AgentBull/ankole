import { Alert, AlertAction, AlertDescription, AlertTitle, Button } from '@ankole/uikit'
import { ErrorCircleRegular } from '@ankole/uikit/icons'
import { useQuery } from '@tanstack/react-query'
import { Suspense, lazy, useState } from 'react'
import { useTranslation } from 'react-i18next'

import * as api from './api/generated/sdk.gen'
import {
  appletEnvKeys,
  appletEnvsQuery,
  canEditAppletEnv,
  openAppletSettings,
  type AppletSettingsTab
} from './applet-settings-state'
import type { PageDetail } from './content-api'

const LazyAppletSettingsDialog = lazy(() =>
  import('./applet-settings').then(module => ({ default: module.AppletSettingsDialog }))
)

export function AppletMissingEnvBanner({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const [fallbackOpen, setFallbackOpen] = useState(false)
  const [fallbackTab, setFallbackTab] = useState<AppletSettingsTab>('environment')
  const isDeleted = Boolean(detail.page.deleted_at)
  const canEdit = canEditAppletEnv(detail)
  const pageID = detail.page.id

  const editorEnvs = useQuery(appletEnvsQuery(pageID, detail.page.revision, !isDeleted && canEdit))
  const viewerStatus = useQuery({
    queryKey: appletEnvKeys.status(pageID, detail.page.revision),
    queryFn: () => api.podAppletEnvStatus({ path: { page_id: pageID } }),
    enabled: !isDeleted && !canEdit
  })

  if (isDeleted) return null

  if (canEdit) {
    const missing = editorEnvs.data?.envs.filter(item => item.required && !item.present) ?? []
    if (missing.length === 0 && !fallbackOpen) return null
    return (
      <>
        {missing.length > 0 ? (
          <Alert variant="warning" className="rounded-lg">
            <ErrorCircleRegular aria-hidden />
            <AlertTitle>{t('pod.env_vars.missing_required_title', { count: missing.length })}</AlertTitle>
            <AlertDescription>
              {t('pod.env_vars.missing_required_editor_description', {
                names: missing.map(item => item.name).join(', ')
              })}
            </AlertDescription>
            <AlertAction>
              <Button
                type="button"
                size="xs"
                variant="outline"
                onClick={() => {
                  if (!openAppletSettings(pageID, { tab: 'environment' })) {
                    setFallbackTab('environment')
                    setFallbackOpen(true)
                  }
                }}>
                {t('pod.env_vars.configure_now')}
              </Button>
            </AlertAction>
          </Alert>
        ) : null}
        {fallbackOpen ? (
          <Suspense fallback={null}>
            <LazyAppletSettingsDialog
              detail={detail}
              open={fallbackOpen}
              onOpenChange={setFallbackOpen}
              tab={fallbackTab}
              onTabChange={setFallbackTab}
            />
          </Suspense>
        ) : null}
      </>
    )
  }

  const missingCount = viewerStatus.data?.missing_required_count ?? 0
  if (missingCount <= 0) return null

  return (
    <Alert variant="warning" className="rounded-lg">
      <ErrorCircleRegular aria-hidden />
      <AlertTitle>{t('pod.env_vars.missing_required_title', { count: missingCount })}</AlertTitle>
      <AlertDescription>{t('pod.env_vars.missing_required_viewer_description')}</AlertDescription>
    </Alert>
  )
}
