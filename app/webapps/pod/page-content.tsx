import { DocumentSubpages } from './page-subpages'
import { Switch } from '@ankole/uikit'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useId, type Ref } from 'react'
import { useTranslation } from 'react-i18next'
import { contentKeys, pageAPI, type PageDetail } from './content-api'
import { ContentError } from './content-primitives'
import type { FileCommentSelection, FilePreviewHandle } from './file-comment-anchors'
import { FilePage } from './page-files'
import { KnowledgePage } from './knowledge-page'
import type { PageDraftModel } from './state/page-draft'
const AppletPage = lazy(() => import('./applet-page').then(module => ({ default: module.AppletPage })))
const BasePage = lazy(() => import('./base-page').then(module => ({ default: module.BasePage })))

export function PageContent({
  detail,
  onRequestFileComment,
  filePreviewRef,
  documentDraft
}: {
  detail: PageDetail
  onRequestFileComment?: (selection: FileCommentSelection) => void
  filePreviewRef?: Ref<FilePreviewHandle | null>
  documentDraft?: InstanceType<typeof PageDraftModel>
}) {
  const { t } = useTranslation()
  switch (detail.page.type) {
    case 'knowledge':
      return <KnowledgePage detail={detail} documentDraft={documentDraft} />
    case 'folder':
      return (
        <>
          <FolderLearning detail={detail} />
          <DocumentSubpages detail={detail} canEdit={detail.actions.includes('node_edit')} hideTopDivider />
        </>
      )
    case 'file':
      return <FilePage detail={detail} onRequestComment={onRequestFileComment} previewRef={filePreviewRef} />
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

function FolderLearning({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const id = useId()
  const client = useQueryClient()
  const setting = detail.fact_learning
  const save = useMutation({
    mutationFn: (extract_facts: boolean) => pageAPI.update(detail.page.id, { extract_facts }),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.all })
  })
  if (!setting || detail.page.deleted_at) return null

  return (
    <div className="mb-4 border-b border-border pb-4">
      <div className="flex items-center justify-between gap-4">
        <div className="space-y-1">
          <label htmlFor={id} className="text-sm font-medium">
            {t('pod.knowledge.learn_folder')}
          </label>
          <p id={`${id}-description`} className="text-xs text-fg-secondary">
            {t(setting.inherited ? 'pod.knowledge.learn_inherited' : 'pod.knowledge.learn_folder_description')}
          </p>
        </div>
        <Switch
          id={id}
          aria-describedby={`${id}-description`}
          checked={setting.enabled || setting.inherited}
          disabled={save.isPending || setting.inherited || !detail.actions.includes('node_manage')}
          onCheckedChange={enabled => save.mutate(enabled)}
        />
      </div>
      <ContentError error={save.error} retry={() => save.mutate(!setting.enabled)} />
    </div>
  )
}
