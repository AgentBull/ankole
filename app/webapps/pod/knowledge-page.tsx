import { KnowledgeReader } from '@ankole/block-editor/reader'
import type { EditorHost } from '@ankole/block-editor/editor'
import { Button } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { lazy, Suspense, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { InternalAPIError } from '../common/internal-api-client'
import { contentKeys, fileURL, pageAPI, type PageDetail } from './content-api'
import { usePageHref } from './use-page-metadata'
import { ContentError, ContentSkeleton } from './content-primitives'
import { useContent } from './content-context'
import { createMentionHostAdapters } from './document-mentions'
import { KnowledgeProperties } from './knowledge-properties'
import { KnowledgePanel } from './knowledge-panel'
import { KnowledgeDraftModel, knowledgeSubmission, acknowledgeKnowledge } from './state/knowledge-draft'
import { DocumentDraftModel } from './state/document-draft'
import { DraftNavigationGuard } from './draft-navigation-guard'
import { DocumentRecovery } from './document-recovery'
import { editorLabels } from './state/editor-labels'
import { refreshDirectories } from './state/navigation-cache'
import { DocumentSubpages } from './page-subpages'
import { uploadPageFile } from './page-files'
import { downloadKnowledge } from './state/document-export'

const KnowledgeEditor = lazy(() => import('./knowledge-editor'))
const DocumentHistory = lazy(() => import('./document-history').then(module => ({ default: module.DocumentHistory })))

export function KnowledgePage({
  detail,
  body,
  draft,
  readTitle,
  hasUnsavedChanges
}: {
  detail: PageDetail
  body: InstanceType<typeof DocumentDraftModel>
  draft: InstanceType<typeof KnowledgeDraftModel>
  readTitle(): string
  hasUnsavedChanges(): boolean
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const content = useContent()
  const pageHref = usePageHref()
  const client = useQueryClient()
  const navigate = useNavigate()
  const historyTrigger = useRef<HTMLButtonElement>(null)
  const editTrigger = useRef<HTMLButtonElement>(null)
  const [history, setHistory] = useState(false)
  const [editorError, setEditorError] = useState<unknown>()
  const metadata = detail.page.metadata ?? {}
  const editing = draft.editing.value
  const wasEditing = useRef(editing)
  useEffect(() => {
    if (wasEditing.current && !editing) editTrigger.current?.focus()
    wasEditing.current = editing
  }, [editing])
  const canEdit = detail.actions.includes('node_edit') && !detail.page.deleted_at
  const source = detail.content?.content ?? '<page/>'
  const host = useMemo<EditorHost>(
    () => ({
      ...createMentionHostAdapters({
        client,
        currentPageID: detail.page.id,
        pageHref: content.pageHref,
        i18n
      }),
      resolveAsset: source =>
        source.startsWith('ankole:asset/')
          ? fileURL(detail.page.id, `assets/${source.slice('ankole:asset/'.length)}`)
          : source,
      uploadAsset: async file => {
        const uploaded = await uploadPageFile(detail.page.id, file, 'asset')
        if (!uploaded.src) throw new Error(t('pod.editor.resource_upload_failed'))
        return { src: uploaded.src, title: file.name, kind: 'image' }
      },
      openPage: id => void navigate({ to: content.pageHref(id) })
    }),
    [client, content, detail.page.id, navigate, i18n, t]
  )
  const save = useMutation({
    mutationFn: ({ generation: _generation, ...input }: ReturnType<typeof knowledgeSubmission>) =>
      pageAPI.write(detail.page.id, input),
    onSuccess: async (result, submitted) => {
      acknowledgeKnowledge(body, draft, submitted, {
        xml: result.content!.content,
        metadata: result.page.metadata ?? {},
        revision: result.page.revision
      })
      client.setQueryData<PageDetail>(contentKeys.page(detail.page.id), current =>
        current ? { ...current, ...result } : current
      )
      await Promise.all([
        client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) }),
        refreshDirectories(client, [])
      ])
    }
  })
  const comparison = useMutation({
    mutationFn: () => pageAPI.read(detail.page.id),
    onSuccess: latest => {
      // Loading a comparison advances only the CAS base. The author's draft stays intact.
      body.revision.value = latest.page.revision
      save.reset()
    }
  })
  const download = useMutation({
    mutationFn: () => downloadKnowledge(detail.page.id, detail.page.title)
  })
  const begin = () => {
    body.xml.value = source
    body.saved(source, detail.page.revision, false)
    draft.begin(metadata)
    comparison.reset()
    save.reset()
  }
  const cancel = () => {
    body.xml.value = body.savedXML.value
    body.saved(body.savedXML.value, body.revision.value, false)
    draft.finish()
    comparison.reset()
    save.reset()
    setEditorError(undefined)
  }
  return (
    <div className="pod-document space-y-4" data-knowledge-page>
      <div className="flex items-center justify-end gap-2">
        <Button variant="ghost" size="sm" disabled={editing || download.isPending} onClick={() => download.mutate()}>
          {t('pod.document.export')}
        </Button>
        {canEdit && (
          <Button ref={historyTrigger} variant="ghost" size="sm" disabled={editing} onClick={() => setHistory(true)}>
            {t('pod.document.history')}
          </Button>
        )}
        {editing ? (
          <>
            <Button variant="outline" size="sm" disabled={save.isPending} onClick={cancel}>
              {t('common.cancel')}
            </Button>
            {canEdit && (
              <Button
                size="sm"
                disabled={save.isPending || !!draft.parsed.value.error}
                onClick={() => save.mutate(knowledgeSubmission(body, draft))}>
                {save.isPending ? t('pod.knowledge.saving') : t('pod.knowledge.save')}
              </Button>
            )}
          </>
        ) : (
          canEdit && (
            <Button ref={editTrigger} size="sm" onClick={begin}>
              {t('pod.knowledge.edit')}
            </Button>
          )
        )}
      </div>
      <fieldset disabled={save.isPending}>
        <KnowledgeProperties
          metadata={editing ? (draft.parsed.value.metadata ?? metadata) : metadata}
          draft={canEdit ? draft : undefined}
        />
      </fieldset>
      <DocumentRecovery model={body} title={readTitle()} />
      <ContentError error={save.error || comparison.error || download.error || editorError} />
      {save.error instanceof InternalAPIError && save.error.status === 409 && (
        <Button variant="outline" size="sm" disabled={comparison.isPending} onClick={() => comparison.mutate()}>
          {t('pod.knowledge.load_latest')}
        </Button>
      )}
      {editing && comparison.data && (
        <details className="border border-border p-3" open>
          <summary className="cursor-pointer text-sm font-medium">{t('pod.knowledge.latest_revision')}</summary>
          <KnowledgeProperties metadata={comparison.data.page.metadata ?? {}} />
          <KnowledgeReader xml={comparison.data.content?.content ?? '<page/>'} host={host} pageHref={pageHref} />
        </details>
      )}
      {editing && canEdit ? (
        <Suspense fallback={<ContentSkeleton variant="text" />}>
          <KnowledgeEditor
            key={draft.generation.value}
            xml={body.xml.value}
            disabled={save.isPending}
            labels={editorLabels(i18n.language)}
            host={host}
            onError={setEditorError}
            onChange={xml => {
              body.xml.value = xml
            }}
          />
        </Suspense>
      ) : (
        <KnowledgeReader xml={editing ? body.xml.value : source} host={host} pageHref={pageHref} />
      )}
      <DocumentSubpages detail={detail} canEdit={canEdit} />
      {!detail.page.deleted_at && <KnowledgePanel pageID={detail.page.id} revision={detail.page.revision} />}
      {history && canEdit && (
        <Suspense fallback={null}>
          <DocumentHistory
            detail={detail}
            readDraft={() => ({
              xml: draft.editing.value ? body.xml.value : source,
              title: readTitle(),
              revision: draft.editing.value ? body.revision.value : detail.page.revision,
              hasUnsavedChanges: hasUnsavedChanges()
            })}
            close={() => setHistory(false)}
            returnFocus={historyTrigger}
          />
        </Suspense>
      )}
    </div>
  )
}

/** Embedded knowledge owns only its body and properties; the containing document owns its title. */
export function EmbeddedKnowledgePage({ detail }: { detail: PageDetail }) {
  useSignals()
  const body = useModel(DocumentDraftModel)
  const draft = useModel(KnowledgeDraftModel)
  body.load(detail.page.id, detail.content?.content ?? '<page/>', detail.page.revision)
  const hasUnsavedChanges = () => body.hasUnsavedChanges.value || draft.dirty.value
  return (
    <>
      <DraftNavigationGuard dirty={hasUnsavedChanges()} />
      <KnowledgePage
        detail={detail}
        body={body}
        draft={draft}
        readTitle={() => detail.page.title}
        hasUnsavedChanges={hasUnsavedChanges}
      />
    </>
  )
}
