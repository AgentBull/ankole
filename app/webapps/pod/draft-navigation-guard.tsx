import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { useBlocker } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'

/** Explicit editors keep their draft when a route or selected file changes. */
export function DraftNavigationGuard({ dirty }: { dirty: boolean }) {
  const { t } = useTranslation()
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) =>
      dirty && (current.pathname !== next.pathname || JSON.stringify(current.search) !== JSON.stringify(next.search)),
    enableBeforeUnload: dirty,
    withResolver: true
  })
  return (
    <Dialog open={blocker.status === 'blocked'} onOpenChange={open => !open && blocker.reset?.()}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogTitle>{t('pod.content.unsaved_changes')}</DialogTitle>
        <p>{t('pod.content.unsaved_changes_leave_warning')}</p>
        <DialogFooter>
          <Button variant="outline" onClick={() => blocker.reset?.()}>
            {t('pod.content.continue_editing')}
          </Button>
          <Button variant="destructive" onClick={() => blocker.proceed?.()}>
            {t('pod.content.discard_changes_and_leave')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
