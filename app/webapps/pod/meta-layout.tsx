import { Outlet, useParams } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { MetaLink } from './meta-navigation'
import { PodSidebarToggle } from './top-bar'

export function MetaLayout() {
  const { t } = useTranslation()
  const { pageID } = useParams({ strict: false })
  if (pageID) return <Outlet />
  return (
    <div className="flex h-full min-h-0 flex-col">
      <header className="flex shrink-0 flex-wrap items-center gap-4 border-b border-border px-5 py-3">
        <PodSidebarToggle />
        <span className="shrink-0 font-semibold">Meta Ankole</span>
        <nav
          aria-label={t('pod.meta.modules')}
          className="flex flex-wrap gap-1 [&>a]:flex-none [&>a]:rounded-control [&>a]:px-2 [&>a]:py-1">
          <MetaLink to="/meta/brain">{t('pod.meta.brain')}</MetaLink>
          <MetaLink to="/meta/skills">{t('pod.meta.skills')}</MetaLink>
          <MetaLink to="/meta/agents">{t('pod.meta.agents')}</MetaLink>
        </nav>
      </header>
      <div className="flex min-h-0 flex-1 flex-col overflow-auto">
        <Outlet />
      </div>
    </div>
  )
}
