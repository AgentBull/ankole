import { lazy, Suspense } from 'react'
import { useTranslation } from 'react-i18next'
import type { PageDetail } from './content-api'
import { FilePage } from './page-files'
const AppletPage = lazy(() => import('./applet-page').then(module => ({ default: module.AppletPage })))
const BasePage = lazy(() => import('./base-page').then(module => ({ default: module.BasePage })))

export function PageContent({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  switch (detail.page.type) {
    case 'file':
      return <FilePage detail={detail} />
    case 'base':
      return (
        <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
          <BasePage detail={detail} />
        </Suspense>
      )
    case 'applet':
      return (
        <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
          <AppletPage detail={detail} />
        </Suspense>
      )
  }
}
