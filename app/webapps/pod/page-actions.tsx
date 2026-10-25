import { t } from 'i18next'
import { DropdownMenuItem, DropdownMenuSeparator, toast } from '@ankole/uikit'
import {
  RiArrowDownLine,
  RiArrowUpLine,
  RiDeleteBinLine,
  RiExternalLinkLine,
  RiFileAddLine,
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
import { contentKeys, pageAPI, type Page } from './content-api'
import { useContent } from './content-context'
import { contentError } from './content-errors'
import { useCopyPageLink } from './page-sharing'
import { canMovePage, stepRequest } from './state/page-move'

const title = (page: Page) => page.title || t('pod.content.untitled')

export type PageActions = ReturnType<typeof usePageActions>

/**
 * Page changes from navigation run at once, and their toasts undo them. Keep this hook in a
 * component that outlives the menu, so an undo still runs after the menu closes.
 */
export function usePageActions() {
  return { move: usePageMove(), trash: usePageTrash(), favorite: usePageFavorite() }
}

function usePageMove() {
  const client = useQueryClient()
  const move = useMutation({
    mutationFn: ({ page, request }: { page: Page; request: PodPageMove; showUndo?: boolean }) =>
      pageAPI.move(page.id, request),
    onSuccess: async (result, { page, showUndo }) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      if (!showUndo) return
      toast.success(t('pod.sidebar.page_moved', { title: title(page) }), {
        action: { label: t('pod.sidebar.undo'), onClick: () => move.mutate({ page, request: result.undo }) }
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
function usePageTrash() {
  const client = useQueryClient()
  const navigate = useNavigate()
  const { pageID } = useParams({ strict: false })
  const restore = useMutation({
    mutationFn: pageAPI.restore,
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.all }),
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  const trash = useMutation({
    mutationFn: (page: Page) => pageAPI.remove(page.id),
    onSuccess: async (_result, page) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      if (podRouteID(pageID) === page.id) void navigate({ to: podLocation('/content/space').pathname })
      toast.success(t('pod.sidebar.page_trashed', { title: title(page) }), {
        action: { label: t('pod.sidebar.undo'), onClick: () => restore.mutate(page.id) }
      })
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  return (page: Page) => trash.mutate(page)
}

function usePageFavorite() {
  const client = useQueryClient()
  const favorite = useMutation({
    mutationFn: ({ page, value }: { page: Page; value: boolean }) => pageAPI.state(page.id, { favorite: value }),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.lists }),
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  return (page: Page, value: boolean) => favorite.mutate({ page, value })
}

/** One action list for a Page row. It renders inside a context menu or a dropdown menu. */
export function PageMenuItems({
  page,
  pages,
  favorited,
  actions: { move, trash, favorite },
  onRename,
  onCreateChild,
  onMoveTo
}: {
  page: Page
  pages: Page[]
  favorited: boolean
  actions: PageActions
  onRename(): void
  onCreateChild(): void
  onMoveTo(): void
}) {
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
              <DropdownMenuItem onClick={onCreateChild}>
                <RiFileAddLine aria-hidden />
                {t('pod.sidebar.new_subpage')}
              </DropdownMenuItem>
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
