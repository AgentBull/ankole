import { BlockEditor } from '@ankole/block-editor'
import { parseXml } from '@ankole/block-editor/document'
import type { EditorHost } from '@ankole/block-editor/editor'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../common/browser-context'
import { contentKeys, fileURL } from './content-api'
import { ContentError } from './content-primitives'
import { createMentionHostAdapters } from './document-mentions'
import { PageIcon } from './page-icon'
import { loadDocumentReferences } from './state/document-export'
import { documentReferenceIDs } from './state/document-tools'
import { documentChanges, documentComparisonSource } from './state/document-history'
import { editorLabels } from './state/editor-labels'

type VersionContent = { content: string; title: string; icon?: string | null }
type Props = { pageID: string; version: VersionContent; current: VersionContent; compare: boolean; editorKey: string }

export function DocumentHistoryPreview(props: Props) {
  return props.compare ? <DocumentComparison {...props} /> : <DocumentVersion {...props} />
}

function DocumentComparison({ pageID, version, current }: Props) {
  const { t } = useTranslation()
  const changes = useMemo(
    () =>
      documentChanges(
        documentComparisonSource(version.content, version.title),
        documentComparisonSource(current.content, current.title)
      ),
    [version, current]
  )
  return (
    <div className="space-y-4" aria-label={t('pod.document.version_changes')}>
      <p className="text-sm text-fg-secondary">{t('pod.document.comparison_direction')}</p>
      <div className="flex flex-wrap gap-4 text-xs">
        <span className="text-destructive">− {t('pod.document.removed_content')}</span>
        <span className="text-success">+ {t('pod.document.added_content')}</span>
      </div>
      {version.icon !== current.icon && (
        <div className="flex items-center gap-3 text-sm">
          <span>{t('pod.document.icon_changed')}</span>
          <PageIcon page={{ type: 'doc', icon: version.icon }} className="size-6" />
          <span aria-hidden>→</span>
          <PageIcon page={{ type: 'doc', icon: current.icon }} className="size-6" />
        </div>
      )}
      {changes.every(change => change.kind === 'unchanged') && version.icon === current.icon ? (
        <p>{t('pod.document.no_changes')}</p>
      ) : (
        <div className="overflow-hidden rounded border border-border font-mono text-sm">
          {changes.map((change, index) => (
            <div
              key={index}
              data-change={change.kind}
              className={
                change.kind === 'removed'
                  ? 'flex bg-destructive/10 text-destructive'
                  : change.kind === 'added'
                    ? 'flex bg-success/10 text-success'
                    : 'flex text-fg-secondary'
              }>
              {change.kind !== 'unchanged' && (
                <span className="sr-only">
                  {t(change.kind === 'removed' ? 'pod.document.removed_content' : 'pod.document.added_content')}
                </span>
              )}
              <span aria-hidden className="w-6 shrink-0 select-none py-1 text-center">
                {change.kind === 'removed' ? '−' : change.kind === 'added' ? '+' : ' '}
              </span>
              <pre className="min-w-0 flex-1 whitespace-pre-wrap break-words p-1 font-mono">{change.text}</pre>
            </div>
          ))}
        </div>
      )}
      <DocumentReferences pageID={pageID} contents={[version.content, current.content]} />
    </div>
  )
}

function DocumentReferences({ pageID, contents }: { pageID: string; contents: string[] }) {
  const client = useQueryClient()
  const ids = [...new Set(contents.flatMap(documentReferenceIDs))].sort()
  const references = useQuery({
    queryKey: [...contentKeys.page(pageID), 'document-references', ids],
    queryFn: () => loadDocumentReferences(client, contents),
    staleTime: 15_000
  })
  return (
    <>
      <ContentError error={references.error} retry={() => void references.refetch()} />
      {!!references.data?.size && (
        <ul className="space-y-2 text-sm">
          {[...references.data].map(([id, reference]) => (
            <li key={id}>
              {reference.restricted ? (
                <span className="text-fg-tertiary">{reference.title}</span>
              ) : (
                <a className="link" href={reference.href} target="_blank" rel="noopener noreferrer">
                  {reference.title}
                </a>
              )}
            </li>
          ))}
        </ul>
      )}
    </>
  )
}

function DocumentVersion({ pageID, version, editorKey }: Props) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const ids = documentReferenceIDs(version.content).sort()
  const references = useQuery({
    queryKey: [...contentKeys.page(pageID), 'document-references', ids],
    queryFn: () => loadDocumentReferences(client, [version.content]),
    staleTime: 15_000
  })
  const labels = useMemo(() => editorLabels(i18n.language), [i18n.language])
  const host = useMemo<EditorHost>(
    () => ({
      ...createMentionHostAdapters({
        client,
        currentPageID: pageID,
        pageHref: id => new URL(podLocation(`/pages/${id}`).pathname, window.location.origin).href,
        openPage: id => {
          const reference = references.data?.get(id)
          if (reference && !reference.restricted) window.open(reference.href, '_blank', 'noopener,noreferrer')
        },
        i18n,
        canQuery: false
      }),
      openPage: id => {
        const reference = references.data?.get(id)
        if (reference && !reference.restricted) window.open(reference.href, '_blank', 'noopener,noreferrer')
      },
      resolveAsset: source =>
        source.startsWith('ankole:asset/') ? fileURL(pageID, `assets/${source.slice('ankole:asset/'.length)}`) : source,
      mountEmbed: (attributes, container) => {
        const reference = attributes.ref && references.data?.get(attributes.ref)
        const accessible = reference && !reference.restricted
        const link = document.createElement(accessible ? 'a' : 'span')
        link.className = 'block rounded border border-border px-4 py-3 text-sm'
        link.textContent = reference ? reference.title : t('pod.content.cannot_display')
        if (accessible && link instanceof HTMLAnchorElement) {
          link.href = reference.href
          link.target = '_blank'
          link.rel = 'noopener noreferrer'
          link.classList.add('link')
        }
        container.append(link)
        return () => link.remove()
      }
    }),
    [client, i18n, pageID, references.data, t]
  )
  if (references.isPending) return <p role="status">{t('pod.content.loading')}</p>
  if (references.error) return <ContentError error={references.error} retry={() => void references.refetch()} />
  return (
    <>
      {!!ids.length && <p className="mb-4 text-xs text-fg-tertiary">{t('pod.document.reference_current')}</p>}
      <BlockEditor
        key={`${editorKey}:${references.dataUpdatedAt}`}
        initial={parseXml(version.content)}
        readOnly
        toolbar={null}
        labels={labels}
        host={host}
      />
    </>
  )
}
