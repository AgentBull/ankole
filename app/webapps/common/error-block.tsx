import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit'
import { RiErrorWarningLine } from '@remixicon/react'
import type { ReactNode } from 'react'
import i18n from './i18n'
import { requestErrorMessage } from './request-errors'

/** Inline request-failure surface shared by every webapp. */
export function ErrorBlock({ action, error, title }: { action?: ReactNode; error: unknown; title?: string }) {
  if (!error) return null
  return (
    <Alert className="min-w-0 overflow-hidden" variant="destructive">
      <RiErrorWarningLine aria-hidden />
      <AlertTitle>{title ?? i18n.t('common.error')}</AlertTitle>
      <AlertDescription className="min-w-0 break-all whitespace-pre-wrap">
        {requestErrorMessage(error)}
      </AlertDescription>
      {action ? <div className="mt-3">{action}</div> : null}
    </Alert>
  )
}
