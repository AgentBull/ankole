import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { contentKeys, pageAPI } from './content-api'
import { ContentError } from './content-primitives'
import { usePageHref, usePagesMetadata } from './use-page-metadata'
import { pageMetadata } from './state/page-metadata'
import { parseKnowledgePanel } from './state/knowledge-panel'
import { PageMention } from './document-mentions'

/** Every row is calculated by the control plane for the current reader. */
export function KnowledgePanel({ pageID, revision }: { pageID: string; revision: number }) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const query = useQuery({
    queryKey: [...contentKeys.page(pageID), 'knowledge', revision],
    queryFn: ({ client }) =>
      pageMetadata(client).read(
        async () => parseKnowledgePanel((await pageAPI.knowledge(pageID)).panel),
        panel => panel.backlinks.map(link => ({ id: link.page_id, title: link.title }))
      )
  })
  const panel = query.data
  const backlinks = usePagesMetadata((panel?.backlinks ?? []).map(link => ({ ...link, id: link.page_id })))
  return (
    <aside className="space-y-4 border-t border-border pt-4" aria-label={t('pod.knowledge.related')}>
      <ContentError error={query.error} retry={() => void query.refetch()} />
      {panel && (
        <>
          {panel.backlinks.length > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-medium">{t('pod.knowledge.backlinks')}</h2>
              <ul className="space-y-1 text-sm">
                {backlinks.map((link, index) => (
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
                      {claim.claim_type === 'fact'
                        ? t('pod.knowledge.fact')
                        : claim.claim_type === 'take'
                          ? t('pod.knowledge.take')
                          : claim.claim_type}
                      {claim.confidence != null &&
                        ` · ${t('pod.knowledge.confidence')}: ${Math.round(claim.confidence * 100)}%`}
                    </p>
                    <p>{claim.claim}</p>
                    {claim.context && <p className="text-fg-secondary">{claim.context}</p>}
                    <p className="text-xs text-fg-tertiary">
                      {[claim.since_date, claim.provenance].filter(Boolean).join(' · ')}
                    </p>
                    {claim.source_node_id && <PageMention id={claim.source_node_id} />}
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
                    {event.source_node_id && <PageMention id={event.source_node_id} />}
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
