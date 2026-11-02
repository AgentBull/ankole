import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { contentKeys, pageAPI } from './content-api'
import { ContentError } from './content-primitives'
import { usePageHref } from './use-page-metadata'

type KnowledgePanelData = {
  backlinks: { page_id: string; title: string; link_type: string; context?: string }[]
  claims: {
    id: string
    claim_type: string
    claim: string
    context?: string
    confidence?: number
    since_date?: string
    provenance?: string
    source_node_id?: string
  }[]
  timelines: {
    id: string
    date: string
    summary: string
    detail?: string
    provenance?: string
    source_node_id?: string
  }[]
  scorecard: { takes: number; brier: number | null }
}

/** Every row is calculated by the control plane for the current reader. */
export function KnowledgePanel({ pageID, revision }: { pageID: string; revision: number }) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const query = useQuery({
    queryKey: [...contentKeys.page(pageID), 'knowledge', revision],
    queryFn: () => pageAPI.knowledge(pageID)
  })
  const panel = query.data?.panel as KnowledgePanelData | undefined
  return (
    <aside className="space-y-4 border-t border-border pt-4" aria-label={t('pod.knowledge.related')}>
      <ContentError error={query.error} retry={() => void query.refetch()} />
      {panel && (
        <>
          {panel.backlinks.length > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-medium">{t('pod.knowledge.backlinks')}</h2>
              <ul className="space-y-1 text-sm">
                {panel.backlinks.map((link, index) => (
                  <li key={`${link.page_id}:${index}`}>
                    <Link className="link" to={pageHref(link.page_id, link.title)}>
                      {link.title}
                    </Link>
                    <span className="ml-2 text-xs text-fg-tertiary">{link.link_type}</span>
                    {link.context && <p className="text-fg-secondary">{link.context}</p>}
                  </li>
                ))}
              </ul>
            </section>
          )}
          {panel.claims.length > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-medium">{t('pod.knowledge.claims')}</h2>
              <ul className="space-y-3 text-sm">
                {panel.claims.map(claim => (
                  <li key={claim.id}>
                    <p className="mb-1 text-xs text-fg-secondary">
                      {t(claim.claim_type === 'fact' ? 'pod.knowledge.fact' : 'pod.knowledge.take')}
                      {claim.confidence != null &&
                        ` · ${t('pod.knowledge.confidence')}: ${Math.round(claim.confidence * 100)}%`}
                    </p>
                    <p>{claim.claim}</p>
                    {claim.context && <p className="text-fg-secondary">{claim.context}</p>}
                    <p className="text-xs text-fg-tertiary">
                      {[claim.since_date, claim.provenance].filter(Boolean).join(' · ')}
                    </p>
                    {claim.source_node_id && (
                      <Link className="link text-xs" to={pageHref(claim.source_node_id)}>
                        {t('pod.knowledge.source')}
                      </Link>
                    )}
                  </li>
                ))}
              </ul>
            </section>
          )}
          {panel.timelines.length > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-medium">{t('pod.knowledge.timeline')}</h2>
              <ol className="space-y-3 text-sm">
                {panel.timelines.map(event => (
                  <li key={event.id}>
                    <time className="mr-2 text-xs text-fg-secondary" dateTime={event.date}>
                      {event.date}
                    </time>
                    {event.summary}
                    {event.detail && <p className="text-fg-secondary">{event.detail}</p>}
                    {event.provenance && <p className="text-xs text-fg-tertiary">{event.provenance}</p>}
                    {event.source_node_id && (
                      <Link className="link text-xs" to={pageHref(event.source_node_id)}>
                        {t('pod.knowledge.source')}
                      </Link>
                    )}
                  </li>
                ))}
              </ol>
            </section>
          )}
          {panel.scorecard.takes > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-medium">{t('pod.knowledge.calibration')}</h2>
              <dl className="flex gap-6 text-sm">
                <div>
                  <dt className="text-fg-secondary">{t('pod.knowledge.resolved_takes')}</dt>
                  <dd>{panel.scorecard.takes}</dd>
                </div>
                {panel.scorecard.brier !== null && (
                  <div>
                    <dt className="text-fg-secondary">Brier</dt>
                    <dd>{panel.scorecard.brier.toFixed(3)}</dd>
                  </div>
                )}
              </dl>
            </section>
          )}
        </>
      )}
    </aside>
  )
}
