import { t } from 'i18next'
import {
  Button,
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
  DrawerTrigger,
  toast
} from '@ankole/uikit'
import { RiHistoryLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { requestErrorMessage } from '../../common/request-errors'
import { podOfficeRestore, podOfficeVersions } from '../api/generated/sdk.gen'
import { contentKeys } from '../content-api'
import { contentError } from '../content-errors'
import { ContentError, ContentSkeleton } from '../content-primitives'

/**
 * Version history drawer shared by Spreadsheet, Word, and Presentation Pages. Restoring a version
 * compacts any uncompacted edits into a `before_restore` snapshot, promotes the chosen package,
 * appends a `reset` log entry, and reloads open editors.
 */
export function OfficeVersions({ pageID }: { pageID: string }) {
  const [open, setOpen] = useState(false)
  const client = useQueryClient()
  const versions = useQuery({
    queryKey: [...contentKeys.page(pageID), 'office-versions'],
    queryFn: ({ signal }) => podOfficeVersions({ path: { id: pageID }, signal }),
    enabled: open
  })
  const restore = useMutation({
    mutationFn: (versionID: string) => podOfficeRestore({ path: { id: pageID, version_id: versionID } }),
    onSuccess: () => {
      toast.success(t('pod.office.version_restored'))
      setOpen(false)
      return client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  return (
    <Drawer open={open} onOpenChange={setOpen} swipeDirection="right">
      <DrawerTrigger
        render={
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={t('pod.office.version_history')}
            title={t('pod.office.version_history')}
          />
        }>
        <RiHistoryLine />
      </DrawerTrigger>
      <DrawerContent aria-label={t('pod.office.version_history')}>
        <DrawerHeader className="border-b border-border p-5">
          <DrawerTitle>{t('pod.office.version_history')}</DrawerTitle>
          <DrawerDescription>{t('pod.office.version_history_description')}</DrawerDescription>
        </DrawerHeader>
        <div className="min-h-0 flex-1 overflow-y-auto p-3">
          <ContentError error={versions.error} retry={() => void versions.refetch()} />
          {versions.isPending && <ContentSkeleton variant="list" rows={5} />}
          <ol className="grid gap-1" aria-label={t('pod.office.versions')}>
            {versions.data?.versions.map(version => (
              <li key={version.id} className="flex items-center gap-3 rounded-control px-2 py-2 hover:bg-accent/60">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium">{t(`pod.office.version_reasons.${version.reason}`)}</p>
                  <p className="truncate text-xs text-fg-tertiary">
                    {[
                      new Date(version.created_at).toLocaleString(),
                      version.author.name ?? version.author.principal_uid,
                      `${Math.ceil(version.size / 1024)} KB`
                    ].join(' · ')}
                  </p>
                </div>
                <Button
                  size="xs"
                  variant="outline"
                  disabled={restore.isPending}
                  onClick={() => restore.mutate(version.id)}>
                  {t('pod.office.restore_version')}
                </Button>
              </li>
            ))}
          </ol>
        </div>
      </DrawerContent>
    </Drawer>
  )
}
