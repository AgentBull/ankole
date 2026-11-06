import { EmbeddedKnowledgePage } from './knowledge-page'
import {
  Button,
  Popover,
  PopoverContent,
  PopoverDescription,
  PopoverTitle,
  PopoverTrigger,
  Switch,
  toast
} from '@ankole/uikit'
import { RiBrainFill, RiBrainLine } from '@remixicon/react'
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

/**
 * The Page header's Learn business facts control, offered to Page managers only.
 * The trigger shows the learning state without opening, and the popover holds the switch.
 */
export function PageLearningButton({ detail }: { detail: PageDetail }) {
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
  const learning = setting.enabled || setting.inherited

  return (
    <Popover>
      <PopoverTrigger
        render={<Button size={learning ? 'sm' : 'icon-sm'} variant="ghost" title={t('pod.knowledge.learn_page')} />}>
        {learning ? <RiBrainFill aria-hidden className="size-4" /> : <RiBrainLine aria-hidden className="size-4" />}
        <span className={learning ? '@max-[640px]:sr-only' : 'sr-only'}>
          {t(learning ? 'pod.knowledge.learning' : 'pod.knowledge.learn_page')}
        </span>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-[min(22rem,calc(100vw-2rem))]">
        <div className="flex items-start justify-between gap-4">
          <div>
            <PopoverTitle id={`${id}-title`}>{t('pod.knowledge.learn_page')}</PopoverTitle>
            <PopoverDescription id={`${id}-description`}>
              {t(setting.inherited ? 'pod.knowledge.learn_inherited' : 'pod.knowledge.learn_page_description')}
            </PopoverDescription>
          </div>
          <Switch
            aria-labelledby={`${id}-title`}
            aria-describedby={`${id}-description`}
            checked={learning}
            disabled={save.isPending || setting.inherited}
            onCheckedChange={enabled => save.mutate(enabled)}
          />
        </div>
        <p className="text-xs text-fg-tertiary">{t('pod.knowledge.learn_visibility')}</p>
      </PopoverContent>
    </Popover>
  )
}
