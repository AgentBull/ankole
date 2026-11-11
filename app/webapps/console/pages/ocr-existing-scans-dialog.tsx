import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  toast
} from '@ankole/uikit'
import { useTranslation } from 'react-i18next'

import {
  getSiteAppConfiguration,
  getSiteUnreadScans,
  updateSiteAppConfiguration
} from '../api/v2-site/generated/sdk.gen'
import { getAppConfiguration, getUnreadScans, updateAppConfiguration } from '../api/v2/generated/sdk.gen'
import { ErrorBlock } from '../../common/error-block'
import { useMutation } from '../tenant-context'

const SETTING_KEY = 'pod.ocr_existing_scans'

type DefaultsScope = 'tenant' | 'global'

/**
 * The scanned PDFs that OCR has not read, and their unread pages. `counting`
 * says that Pod is still listing earlier PDFs, so the numbers will grow.
 */
export type UnreadScans = { files: number; pages: number; counting: boolean }

/**
 * What Console must know before it asks about the scans uploaded earlier:
 * whether reading them is already on, by the value that takes effect at
 * `scope`, and how many files and pages are waiting. A Pod without its own
 * value follows the Site's. `unread` is missing when Console could not count.
 */
export async function ocrExistingScansQuestion(scope: DefaultsScope) {
  const request = { path: { key: SETTING_KEY }, throwOnError: true } as const
  const response = scope === 'global' ? await getSiteAppConfiguration(request) : await getAppConfiguration(request)
  const setting = response.data.app_configuration
  const enabled = (setting.overridden ? setting.value : setting.fallback_value) === true
  if (enabled) return { enabled }

  const count = scope === 'global' ? getSiteUnreadScans({ throwOnError: true }) : getUnreadScans({ throwOnError: true })
  const unread: UnreadScans | undefined = await count.then(
    counted => counted.data,
    () => undefined
  )
  return { enabled, unread }
}

/**
 * Asks whether Pod should also read the scanned PDFs uploaded before the OCR
 * model was saved, and shows how many files and pages that is. The OCR
 * provider charges for every page, so Pod reads none of them until an
 * administrator accepts the charges here. While Pod is still listing earlier
 * PDFs the numbers are marked incomplete. Declining stores the refusal, so a
 * Site-level consent does not reach a Pod that said no; closing the dialog
 * stores nothing.
 */
export function OcrExistingScansDialog({
  scope,
  unread,
  open,
  onOpenChange
}: {
  scope: DefaultsScope
  unread: UnreadScans | undefined
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useTranslation()
  const answer = useMutation({
    mutationFn: async (value: boolean) => {
      const request = { path: { key: SETTING_KEY }, body: { data: { value } }, throwOnError: true } as const
      if (scope === 'global') await updateSiteAppConfiguration(request)
      else await updateAppConfiguration(request)
      return value
    },
    onSuccess: accepted => {
      if (accepted) toast.success(t('console.models.ocr_existing_scans_enabled'))
      onOpenChange(false)
    }
  })

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.models.ocr_existing_scans_title')}</DialogTitle>
          <DialogDescription>{t(`console.models.ocr_existing_scans_description_${scope}`)}</DialogDescription>
        </DialogHeader>
        {unread ? (
          <p className="text-sm font-medium">
            {t(`console.models.ocr_existing_scans_pending_${scope}`, unread)}
            {unread.counting ? ` ${t('console.models.ocr_existing_scans_counting')}` : ''}
          </p>
        ) : null}
        <ErrorBlock error={answer.error} />
        <DialogFooter>
          <Button
            disabled={answer.isPending}
            size="sm"
            type="button"
            variant="ghost"
            onClick={() => answer.mutate(false)}>
            {t('console.models.ocr_existing_scans_decline')}
          </Button>
          <Button disabled={answer.isPending} size="sm" type="button" onClick={() => answer.mutate(true)}>
            {t('console.models.ocr_existing_scans_confirm')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
