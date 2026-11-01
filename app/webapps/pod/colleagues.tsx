import { SidebarTrigger, buttonVariants } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { agentsQuery } from './api'
import { ContentError } from './content-primitives'
import { ChatAvatar } from './chat/chat-avatar'

export function Colleagues() {
  const { t } = useTranslation()
  const query = useQuery(agentsQuery)
  return (
    <section className="flex h-full min-h-0 flex-col">
      <header className="sheet-header gap-2">
        <SidebarTrigger label={t('pod.sidebar.expand')} />
        <h1 className="sheet-title">{t('pod.colleagues.title')}</h1>
      </header>
      <div className="overflow-auto p-6 md:p-10">
        <p className="mb-6 text-sm text-fg-secondary">{t('pod.colleagues.description')}</p>
        <ContentError error={query.error} retry={() => void query.refetch()} />
        {query.isPending && <p role="status">{t('pod.chat.loading_agents')}</p>}
        {query.isSuccess && !query.data.agents.length && <p>{t('pod.chat.no_agents')}</p>}
        <ul className="divide-y divide-border">
          {query.data?.agents.map(agent => (
            <li key={agent.uid} className="flex items-start gap-3 py-4">
              <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
              <div className="min-w-0 flex-1">
                <h2 className="font-medium">{agent.displayName}</h2>
                <p className="break-all text-xs text-fg-tertiary">@{agent.uid}</p>
                {agent.role && <p className="mt-2 whitespace-pre-wrap text-sm text-fg-secondary">{agent.role}</p>}
              </div>
              <Link to="/" search={{ agent: agent.uid }} className={buttonVariants({ variant: 'outline', size: 'sm' })}>
                {t('pod.colleagues.chat')}
              </Link>
            </li>
          ))}
        </ul>
      </div>
    </section>
  )
}
