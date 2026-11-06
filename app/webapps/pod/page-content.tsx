import { EmbeddedKnowledgePage } from './knowledge-page'
import { DropdownMenuCheckboxItem, toast } from '@ankole/uikit'
import { RiBrainLine } from '@remixicon/react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useId, type Ref } from 'react'
import { useTranslation } from 'react-i18next'
import { contentKeys, pageAPI, type PageDetail } from './content-api'
import { requestErrorMessage } from '../common/request-errors'
import { contentError } from './content-errors'
import type { FileCommentSelection, FilePreviewHandle } from './file-comment-anchors'
import { FilePage } from './page-files'
const AppletPage = lazy(() => import('./applet-page').then(module => ({ default: module.AppletPage })))
const BasePage = lazy(() => import('./base-page').then(module => ({ default: module.BasePage })))

export function PageContent({
  detail,
  onRequestFileComment,
  filePreviewRef
}: {
  detail: PageDetail
  onRequestFileComment?: (selection: FileCommentSelection) => void
  filePreviewRef?: Ref<FilePreviewHandle | null>
}) {
  const { t } = useTranslation()
  switch (detail.page.type) {
    case 'knowledge':
      return <EmbeddedKnowledgePage detail={detail} />
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

/** The page menu's Learn business facts toggle, offered to Page managers only. */
export function PageLearningMenuItem({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const id = useId()
  const client = useQueryClient()
  const setting = detail.fact_learning
  const save = useMutation({
    mutationFn: (extract_facts: boolean) => pageAPI.update(detail.page.id, { extract_facts }),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.all }),
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  if (!setting || detail.page.deleted_at || !detail.actions.includes('node_manage')) return null

  return (
    <DropdownMenuCheckboxItem
      checked={setting.enabled || setting.inherited}
      disabled={save.isPending || setting.inherited}
      aria-describedby={`${id}-description`}
      onCheckedChange={enabled => save.mutate(enabled)}>
      <RiBrainLine aria-hidden />
      <span className="flex max-w-64 flex-col gap-0.5">
        <span>{t('pod.knowledge.learn_page')}</span>
        <span id={`${id}-description`} className="text-xs text-fg-secondary">
          {t(setting.inherited ? 'pod.knowledge.learn_inherited' : 'pod.knowledge.learn_page_description')}
        </span>
      </span>
    </DropdownMenuCheckboxItem>
  )
}
