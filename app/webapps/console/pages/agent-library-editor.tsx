import { useQuery } from '../tenant-context'
import { Skeleton } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { listAgentLibraryDocumentsOptions } from '../api/v2/generated/@tanstack/react-query.gen'
import { ErrorBlock } from '../../common/error-block'

/** Agent contracts are edited at their source pages in the Pod. */
export function AgentLibraryEditor({ agentUID }: { agentUID: string }) {
  const { t } = useTranslation()
  const documents = useQuery(listAgentLibraryDocumentsOptions({ path: { agent_uid: agentUID } }))

  return (
    <section className="grid min-w-0 gap-4">
      <div className="grid gap-1">
        <h3 className="title-section">{t('console.agent_library.title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.agent_library.description')}</p>
        <p className="text-xs leading-5 text-muted-foreground">{t('console.agent_library.effect_hint')}</p>
      </div>
      <ErrorBlock error={documents.error} />
      {documents.isPending ? <Skeleton className="h-20 w-full" /> : null}
      {documents.data ? (
        <ul className="grid gap-3">
          {(['agents', 'design'] as const).map(kind => (
            <li key={kind} className="grid gap-2">
              <span className="font-medium">{kind === 'agents' ? 'AGENTS.md' : 'DESIGN.md'}</span>
              <ol className="list-inside list-decimal space-y-1">
                {documents.data.library_documents[kind].page_urls.map((url, index) => (
                  <li key={url}>
                    <a href={url} className="text-sm underline underline-offset-4">
                      {t('console.agent_library.open_source', { index: index + 1 })}
                    </a>
                  </li>
                ))}
              </ol>
            </li>
          ))}
        </ul>
      ) : null}
    </section>
  )
}
