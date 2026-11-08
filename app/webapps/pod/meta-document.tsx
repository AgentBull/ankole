import { KnowledgeReader } from '@ankole/block-editor/reader'
import { Button } from '@ankole/uikit'
import { useModel, useSignal } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { DocumentDraftModel } from './state/document-draft'
import { DraftNavigationGuard } from './draft-navigation-guard'
import { createMentionHostAdapters } from './document-mentions'
import { usePageHref } from './use-page-metadata'
import { ContentError, ContentSkeleton } from './content-primitives'
import { KnowledgeProperties } from './knowledge-properties'
import {
  KnowledgeDraftModel,
  knowledgeSubmission,
  acknowledgeKnowledge,
  type KnowledgeMetadata
} from './state/knowledge-draft'
import { editorLabels } from './state/editor-labels'

const Editor = lazy(() => import('./knowledge-editor'))

/** A document draft preserves local edits while the author reconciles a newer saved revision. */
export function MetaDocument<Result>({
  title,
  xml,
  metadata,
  revision,
  canEdit,
  save,
  children,
  onBegin,
  onSaved,
  pendingChanges = false,
  bodyEnabled = true
}: {
  title: string
  xml: string
  metadata: KnowledgeMetadata
  revision: number
  canEdit: boolean
  pendingChanges?: boolean
  save: (value: { xml: string; metadata: KnowledgeMetadata; base_revision: number }) => Promise<Result>
  onSaved?: (result: Result) => void
  onBegin?: () => void
  bodyEnabled?: boolean | ((editing: boolean) => boolean)
  children?: ReactNode | ((editing: boolean) => ReactNode)
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const draft = useModel(KnowledgeDraftModel)
  const body = useModel(DocumentDraftModel)
  const client = useQueryClient()
  const pageHref = usePageHref()
  const host = useMemo(() => createMentionHostAdapters({ client, pageHref, i18n }), [client, pageHref, i18n])
  const [reviewing, setReviewing] = useState(false)
  const editorError = useSignal<unknown>(null)
  const showBody = typeof bodyEnabled === 'function' ? bodyEnabled(draft.editing.value) : bodyEnabled
  const mutation = useMutation({
    mutationFn: ({ generation: _generation, ...input }: ReturnType<typeof knowledgeSubmission>) => save(input),
    onSuccess: (result, submitted) => {
      acknowledgeKnowledge(body, draft, submitted)
      onSaved?.(result)
    }
  })
  const begin = () => {
    onBegin?.()
    body.xml.value = xml
    body.saved(xml, revision, false)
    draft.begin(metadata)
    setReviewing(false)
    editorError.value = null
    mutation.reset()
  }
  return (
    <section className="space-y-4 rounded-lg border border-border p-5">
      <DraftNavigationGuard
        dirty={draft.editing.value && (body.hasUnsavedChanges.value || draft.dirty.value || pendingChanges)}
      />
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="font-semibold">{title}</h2>
        {canEdit && !draft.editing.value && (
          <Button size="sm" variant="outline" onClick={begin}>
            {t('common.edit')}
          </Button>
        )}
        {draft.editing.value && (
          <div className="flex gap-2">
            <Button
              size="sm"
              variant="ghost"
              disabled={mutation.isPending}
              onClick={() => {
                draft.finish()
                mutation.reset()
              }}>
              {t('common.cancel')}
            </Button>
            <Button
              size="sm"
              disabled={mutation.isPending || !!draft.parsed.value.error}
              onClick={() => mutation.mutate(knowledgeSubmission(body, draft))}>
              {t('common.save')}
            </Button>
          </div>
        )}
      </div>
      {typeof children === 'function' ? children(draft.editing.value) : children}
      {showBody && <KnowledgeProperties metadata={metadata} draft={draft} />}
      {showBody &&
        (draft.editing.value ? (
          <Suspense fallback={<ContentSkeleton variant="text" />}>
            <Editor
              key={draft.generation.value}
              xml={body.xml.value}
              host={host}
              labels={editorLabels(i18n.language)}
              disabled={mutation.isPending}
              onChange={value => {
                body.xml.value = value
              }}
              onError={error => {
                editorError.value = error
              }}
            />
          </Suspense>
        ) : (
          <KnowledgeReader xml={xml} host={host} pageHref={pageHref} />
        ))}
      {mutation.isSuccess && (
        <p role="status" className="text-sm text-fg-secondary">
          {t('pod.meta.saved')}
        </p>
      )}
      {!!(mutation.error || editorError.value) && <ContentError error={mutation.error || editorError.value} />}
      {(reviewing || (mutation.isError && revision !== body.revision.value)) && (
        <div className="space-y-3">
          <p className="text-sm text-fg-secondary">{t('pod.meta.draft_conflict')}</p>
          <details open={reviewing} className="rounded border border-border p-3">
            <summary>{t('pod.knowledge.latest_revision')}</summary>
            <KnowledgeProperties metadata={metadata} />
            <KnowledgeReader xml={xml} host={host} pageHref={pageHref} />
          </details>
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              body.revision.value = revision
              setReviewing(true)
              mutation.reset()
            }}>
            {t('pod.knowledge.load_latest')}
          </Button>
          <Button variant="ghost" size="sm" onClick={begin}>
            {t('pod.meta.load_latest')}
          </Button>
        </div>
      )}
    </section>
  )
}
