import { t } from 'i18next'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useState, type RefObject } from 'react'
import { contentKeys, pageAPI, pageChildrenQuery, pageQuery, type Page } from './content-api'
import { ContentError } from './content-primitives'

const PagePicker = lazy(() => import('./page-picker').then(module => ({ default: module.PagePicker })))

export function MovePageDialog({
  page,
  beforeMove,
  close,
  returnFocus
}: {
  page: Page
  beforeMove?(): Promise<void>
  close(): void
  returnFocus?: RefObject<HTMLElement | null>
}) {
  const currentTarget = page.parent_id ?? (page.private_owner_uid ? `private:${page.private_owner_uid}` : 'space')
  const [target, setTarget] = useState(currentTarget)
  const [selectedPage, setSelectedPage] = useState<Page>()
  const privatePages = useInfiniteQuery(pageChildrenQuery('private'))
  const currentParent = useQuery({ ...pageQuery(page.parent_id ?? ''), enabled: Boolean(page.parent_id) })
  const client = useQueryClient()
  const canCreateSpace = privatePages.data?.pages[0]?.can_create_space === true
  const privateOwner = privatePages.data?.pages[0]?.principal_uid
  const privateTarget = privateOwner ? `private:${privateOwner}` : undefined
  const privateLocation = target.startsWith('private:')
  const waitingForIdentity = privateLocation && !privateOwner
  const move = useMutation({
    mutationFn: async () => {
      if (waitingForIdentity) throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_the'))
      if (!validTarget || target === currentTarget) throw new Error(t('pod.content.choose_an_available_destination'))
      await beforeMove?.()
      return pageAPI.move(page.id, {
        parent_id: target === 'space' || target === privateTarget ? null : target,
        private_owner_uid: target === privateTarget ? privateOwner : null
      })
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      close()
    }
  })
  const validTarget =
    (target === privateTarget && privatePages.data?.pages[0]?.can_create_private === true) ||
    (target === 'space' && canCreateSpace) ||
    selectedPage?.id === target
  const targetTitle =
    target === 'space'
      ? t('pod.content.space')
      : privateLocation
        ? privateOwner
          ? target === privateTarget
            ? 'Private'
            : t('pod.content.shared_with_me')
          : t('pod.content.loading_private')
        : selectedPage?.title ||
          (target === page.parent_id ? currentParent.data?.page.title : undefined) ||
          t('pod.content.untitled')
  return (
    <Dialog open onOpenChange={next => !next && !move.isPending && close()}>
      <DialogContent
        className="pod-dialog pod-picker-dialog"
        closeLabel={t('common.close')}
        finalFocus={returnFocus}
        showCloseButton={!move.isPending}>
        <DialogTitle>{t('pod.content.move_page')}</DialogTitle>
        <div className="pod-dialog-body grid gap-3">
          <Suspense fallback={<p role="status">{t('pod.content.loading_destinations')}</p>}>
            <PagePicker
              label={t('pod.content.destination')}
              excludeSubtreeOf={page.id}
              requiredAction="page_edit"
              roots={[
                ...(canCreateSpace ? [{ id: 'space', title: t('pod.content.space') }] : []),
                ...(privateTarget && privatePages.data?.pages[0]?.can_create_private
                  ? [{ id: privateTarget, title: 'Private', private: true }]
                  : [])
              ]}
              selected={target}
              onSelect={(id, candidate) => {
                setTarget(id)
                setSelectedPage(candidate)
              }}
              disabled={move.isPending}
            />
          </Suspense>
          <p className="pod-selected-destination text-sm" aria-live="polite">
            <span className="text-fg-tertiary">{t('pod.content.destination')}: </span>
            {targetTitle}
          </p>
          {target !== currentTarget && (
            <p className="text-xs text-fg-tertiary">
              {t('pod.content.the_page_and_its_subpages_move_together_pages_with_inherited')}
            </p>
          )}
          {waitingForIdentity && !privatePages.error && <p role="status">{t('pod.content.loading_private')}</p>}
          <ContentError
            error={move.error || (privateLocation ? privatePages.error : undefined)}
            retry={() => {
              if (privateLocation) void privatePages.refetch()
            }}
          />
        </div>
        <DialogFooter>
          <Button variant="ghost" disabled={move.isPending} onClick={close}>
            {t('pod.content.cancel')}
          </Button>
          <Button
            disabled={!validTarget || target === currentTarget || waitingForIdentity || move.isPending}
            variant="outline"
            onClick={() => move.mutate()}>
            {move.isPending ? t('pod.content.moving') : t('pod.content.move')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
