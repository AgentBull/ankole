import { DocumentSubpages } from './page-subpages'
import { lazy, Suspense, type Ref } from 'react'
import { useTranslation } from 'react-i18next'
import type { PageDetail } from './content-api'
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
    case 'folder':
      return <DocumentSubpages detail={detail} canEdit={detail.actions.includes('node_edit')} hideTopDivider />
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
