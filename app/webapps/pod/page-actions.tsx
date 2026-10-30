import { usePageMetadata } from './use-page-metadata'
import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenuItem,
  DropdownMenuSeparator,
  toast
} from '@ankole/uikit'
import {
  RiArrowDownLine,
  RiArrowUpLine,
  RiDeleteBinLine,
  RiExternalLinkLine,
  RiFileCopyLine,
  RiFolderTransferLine,
  RiPencilLine,
  RiStarFill,
  RiStarLine
} from '@remixicon/react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate, useParams } from '@tanstack/react-router'
import type { PageMove as PodPageMove } from './content-api'
import { podLocation, podRouteID } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { cachedPages, contentKeys, pageAPI, type Page, type PageDetail } from './content-api'
import { useContent } from './content-context'
import { contentError } from './content-errors'
import { useCopyPageLink } from './page-sharing'
import { canMovePage, stepRequest } from './state/page-move'
import { CreatePageSubmenu, useSubpageCreation } from './page-create-menu'

import { pageCreated, pageRemoved, pageMoved } from './state/navigation-cache'

const title = (page: Page) => page.title || t('pod.content.untitled')

export type PageActions = ReturnType<typeof usePageActions>

/**
 * Page changes from navigation run at once, and their toasts undo them. Keep this hook in a
 * component that outlives the menu, so an undo still runs after the menu closes.
 */
export function usePageActions() {
  const trash = usePageTrash()
  return {
    move: usePageMove(),
    trash: trash.mutate,
    favorite: usePageFavorite(),
    createSubpage: useSubpageCreation()
  }
}

function usePageMove() {
  const client = useQueryClient()
  const move = useMutation({
    mutationFn: ({ page, request }: { page: Page; request: PodPageMove; showUndo?: boolean }) =>
      pageAPI.move(page.id, request),
    onSuccess: (result, { page, showUndo }) => {
      pageMoved(client, result.page, page)
      if (!showUndo) return
      toast.success(t('pod.sidebar.page_moved', { title: title(page) }), {
        action: {
          label: t('pod.sidebar.undo'),
          onClick: () => move.mutate({ page: result.page, request: result.undo })
        }
      })
    },
    onError: error => {
      toast.error(requestErrorMessage(contentError(error)))
      void client.invalidateQueries({ queryKey: contentKeys.lists })
    }
  })
  return (page: Page, request: PodPageMove) => move.mutate({ page, request, showUndo: true })
}

/** Trash runs at once; the toast restores the page. */
export function usePageTrash(onRemoved?: () => void) {
  const client = useQueryClient()
  const navigate = useNavigate()
  const { pageID } = useParams({ strict: false })
  const restore = useMutation({
    mutationFn: pageAPI.restore,
    onSuccess: ({ page }) => pageCreated(client, page),
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  return useMutation({
    mutationFn: (page: Page) => pageAPI.remove(page.id),
    onSuccess: (_result, page) => {
      onRemoved?.()
      const parent =
        page.parent_id &&
        (client.getQueryData<PageDetail>(contentKeys.page(page.parent_id))?.page ??
          cachedPages(client).find(candidate => candidate.id === page.parent_id))
      pageRemoved(client, page)
      if (podRouteID(pageID) === page.id) {
        const destination = parent ? `/pages/${parent.id}` : `/content/${page.private_owner_uid ? 'private' : 'space'}`
        void navigate({ to: podLocation(destination).pathname })
      }
      toast.success(t('pod.sidebar.page_trashed', { title: title(page) }), {
        action: { label: t('pod.sidebar.undo'), onClick: () => restore.mutate(page.id) }
      })
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
}

export function usePagePurge(onPurged?: () => void) {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (page: Page) => pageAPI.purge(page.id),
    onSuccess: (_result, page) => {
      pageRemoved(client, page)
      onPurged?.()
      toast.success(t('pod.content.page_permanent_deletion_started', { title: title(page) }))
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
}

export function PermanentDeletePageDialog({
  page: sourcePage,
  pending,
  onCancel,
  onConfirm
}: {
  page: Page
  pending: boolean
  onCancel(): void
  onConfirm(): void
}) {
  const { t } = useTranslation()
  const page = usePageMetadata(sourcePage)
  return (
    <Dialog open onOpenChange={open => !open && !pending && onCancel()}>
      <DialogContent className="pod-dialog" closeLabel={t('common.close')} showCloseButton={!pending}>
        <DialogTitle>{t('pod.content.permanently_delete_page')}</DialogTitle>
        <p className="text-sm">{t('pod.content.permanently_delete_page_confirmation', { title: title(page) })}</p>
        <DialogFooter>
          <Button variant="outline" disabled={pending} onClick={onCancel}>
            {t('common.cancel')}
          </Button>
          <Button variant="destructive" disabled={pending} onClick={onConfirm}>
            {pending ? t('pod.content.permanently_deleting') : t('pod.content.permanently_delete')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function usePageFavorite() {
  const client = useQueryClient()
  const favorite = useMutation({
    mutationFn: ({ page, value }: { page: Page; value: boolean }) => pageAPI.state(page.id, { favorite: value }),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.list('favorites') }),
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  return (page: Page, value: boolean) => favorite.mutate({ page, value })
}

/** One action list for a Page row. It renders inside a context menu or a dropdown menu. */
export function PageMenuItems({
  page,
  pages,
  favorited,
  actions: { move, trash, favorite, createSubpage },
  onRename,
  onMoveTo
}: {
  page: Page
  pages: Page[]
  favorited: boolean
  actions: PageActions
  onRename(): void
  onMoveTo(): void
}) {
  const { t } = useTranslation()
  const { pageHref } = useContent()
  const copyLink = useCopyPageLink(page.id)
  const canEdit = page.actions?.includes('page_edit') === true
  const canManage = page.actions?.includes('page_manage') === true
  const canMove = canMovePage(page)
  const up = canMove ? stepRequest(pages, page, -1) : null
  const down = canMove ? stepRequest(pages, page, 1) : null
  return (
    <>
      <DropdownMenuItem onClick={() => window.open(pageHref(page.id), '_blank', 'noopener')}>
        <RiExternalLinkLine aria-hidden />
        {t('pod.sidebar.open_in_new_tab')}
      </DropdownMenuItem>
      <DropdownMenuItem onClick={() => void copyLink()}>
        <RiFileCopyLine aria-hidden />
        {t('pod.content.copy_link')}
      </DropdownMenuItem>
      <DropdownMenuItem onClick={() => favorite(page, !favorited)}>
        {favorited ? <RiStarFill aria-hidden /> : <RiStarLine aria-hidden />}
        {favorited ? t('pod.sidebar.remove_favorite') : t('pod.sidebar.add_favorite')}
      </DropdownMenuItem>
      {canMove && (
        <>
          <DropdownMenuSeparator />
          {canEdit && (
            <>
              <CreatePageSubmenu create={createSubpage(page.id)} />
              <DropdownMenuItem onClick={onRename}>
                <RiPencilLine aria-hidden />
                {t('pod.sidebar.rename')}
              </DropdownMenuItem>
            </>
          )}
          <DropdownMenuItem disabled={!up} onClick={() => up && move(page, up)}>
            <RiArrowUpLine aria-hidden />
            {t('pod.sidebar.move_up')}
          </DropdownMenuItem>
          <DropdownMenuItem disabled={!down} onClick={() => down && move(page, down)}>
            <RiArrowDownLine aria-hidden />
            {t('pod.sidebar.move_down')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={onMoveTo}>
            <RiFolderTransferLine aria-hidden />
            {t('pod.sidebar.move_to')}
          </DropdownMenuItem>
        </>
      )}
      {canManage && (
        <>
          <DropdownMenuSeparator />
          <DropdownMenuItem variant="destructive" onClick={() => trash(page)}>
            <RiDeleteBinLine aria-hidden />
            {t('pod.content.move_to_trash')}
          </DropdownMenuItem>
        </>
      )}
    </>
  )
}
