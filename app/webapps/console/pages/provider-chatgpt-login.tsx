import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Spinner,
  Textarea,
  toast
} from '@ankole/uikit'
import { OpenRegular } from '@ankole/uikit/icons'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorCode, requestErrorDetails, requestErrorMessage } from '../../common/request-errors'
import { DiscardConfirmDialog, LabeledField, ReadOnlyValue, useDialogDiscardGuard } from '../console-form'
import { ChatGPTLoginModel } from '../state/chatgpt-login-model'
import type { AIGatewayCredentialPoolEntry, AIGatewayProviderItem } from '../state/provider-settings'

// Coded ChatGPT sign-in failures and whether their message interpolates the
// upstream response. Each code's locale key is `console.providers.<code>`.
const chatGPTLoginErrorCodes: Record<string, { upstream: boolean }> = {
  chatgpt_login_rejected: { upstream: true },
  chatgpt_login_unreachable: { upstream: true },
  chatgpt_refresh_failed: { upstream: true },
  chatgpt_login_denied: { upstream: false },
  chatgpt_login_expired: { upstream: false },
  chatgpt_login_invalid: { upstream: false }
}

/**
 * Localizes coded ChatGPT sign-in failures and keeps the real upstream
 * response visible; unknown failures fall back to the envelope message.
 */
function chatGPTLoginErrorText(
  error: unknown,
  t: {
    (key: string): string
    (key: string, values: Record<string, string>): string
  }
): string {
  if (typeof error === 'string') return error
  const code = requestErrorCode(error) ?? ''
  const entry = chatGPTLoginErrorCodes[code]
  if (!entry) return requestErrorMessage(error)
  if (!entry.upstream) return t(`console.providers.${code}`)

  const details = requestErrorDetails(error)
  const status = details.upstream_status
  const upstreamCode = details.upstream_code ?? details.transport
  const upstream = [
    typeof status === 'number' ? `HTTP ${status}` : undefined,
    typeof upstreamCode === 'string' ? upstreamCode : undefined
  ]
    .filter(Boolean)
    .join(', ')
  return upstream ? t(`console.providers.${code}`, { upstream }) : requestErrorMessage(error)
}

export function ChatGPTLoginDialog({
  entry,
  onOpenChange,
  open,
  provider
}: {
  entry: AIGatewayCredentialPoolEntry | null | undefined
  onOpenChange: (open: boolean) => void
  open: boolean
  provider: AIGatewayProviderItem
}) {
  useSignals()
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const model = useModel(ChatGPTLoginModel)

  model.setOnCompleted(() => {
    void queryClient.invalidateQueries()
    toast.success(t('console.providers.chatgpt_login_complete'))
    onOpenChange(false)
  })

  useEffect(() => {
    if (!open) {
      model.close()
      return
    }
    model.open({
      providerID: provider.provider_id,
      entryID: entry?.id,
      label: entry?.label ?? '',
      priority: String(entry?.priority ?? 0)
    })
    return () => {
      model.close()
    }
  }, [entry, model, open, provider.provider_id])

  const validationKey = model.validationError.value
  const modelError = model.error.value
  const submitting = model.submitting.value
  const login = model.login.value
  const label = model.label.value
  const priority = model.priority.value
  const callbackURL = model.callbackURL.value
  const loginContext = model.loginContext.value
  const dirty = model.dirty.value
  const showingMetadataFields = model.showingMetadataFields.value
  const showingDeviceFlow = model.showingDeviceFlow.value
  const showingBrowserPaste = model.showingBrowserPaste.value
  const polling = model.polling.value
  const retryAfter = model.retryAfter.value
  const isRestart = model.isRestart.value
  const validationMessage =
    validationKey === 'credential_label_required'
      ? t('console.providers.credential_label_required')
      : validationKey === 'callback_url_required'
        ? t('common.field_required', { field: t('console.providers.callback_url') })
        : undefined
  const error = validationMessage ?? modelError
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending: submitting, onOpenChange })

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!submitting}>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            model.submit()
          }}>
          <DialogHeader>
            <DialogTitle>
              {entry ? t('console.providers.reauthenticate') : t('console.providers.add_chatgpt_account')}
            </DialogTitle>
            <DialogDescription>{t('console.providers.chatgpt_login_description')}</DialogDescription>
          </DialogHeader>

          <div className="grid gap-4">
            {error ? (
              <p className="text-sm text-destructive-fg" aria-live="assertive">
                {chatGPTLoginErrorText(error, t)}
              </p>
            ) : null}
            {showingMetadataFields ? (
              <>
                <LabeledField label={t('console.providers.credential_label')} required>
                  <Input value={label} onChange={event => model.setLabel(event.target.value)} />
                </LabeledField>
                <LabeledField label={t('console.providers.priority')}>
                  <Input
                    type="number"
                    step={1}
                    value={priority}
                    onChange={event => model.setPriority(event.target.value)}
                  />
                </LabeledField>
              </>
            ) : null}

            {showingDeviceFlow ? (
              <div className="grid gap-4 border border-border-subtle bg-layer-03/30 p-4">
                <p className="text-sm">{t('console.providers.device_login_instructions')}</p>
                <a
                  className="link inline-flex items-center gap-1 text-sm"
                  href={textValue(login?.verification_url)}
                  target="_blank"
                  rel="noreferrer">
                  {textValue(login?.verification_url)}
                  <OpenRegular className="size-4" aria-hidden />
                </a>
                <ReadOnlyValue mono>{textValue(login?.user_code)}</ReadOnlyValue>
                <p className="text-xs text-fg-secondary">
                  {polling
                    ? t('console.providers.device_login_polling')
                    : t('console.providers.device_login_waiting', { seconds: retryAfter })}
                </p>
              </div>
            ) : null}

            {showingBrowserPaste ? (
              <div className="grid gap-4 border border-border-subtle bg-layer-03/30 p-4">
                <p className="text-sm">{t('console.providers.browser_login_instructions')}</p>
                <a
                  className="link inline-flex items-center gap-1 text-sm"
                  href={textValue(login?.authorization_url)}
                  target="_blank"
                  rel="noreferrer">
                  {t('console.providers.open_authorization')}
                  <OpenRegular className="size-4" aria-hidden />
                </a>
                <LabeledField label={t('console.providers.callback_url')} required>
                  <Textarea
                    className="min-h-24 font-mono text-xs"
                    value={callbackURL}
                    onChange={event => model.setCallbackURL(event.target.value)}
                  />
                </LabeledField>
              </div>
            ) : null}
          </div>

          <DialogFooter>
            <Button type="button" variant="ghost" disabled={submitting} onClick={() => guard.requestOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            {showingMetadataFields ? (
              <Button
                aria-busy={submitting}
                type="submit"
                disabled={submitting}
                incomplete={!label.trim() && !submitting}>
                {submitting ? <Spinner aria-hidden data-icon="inline-start" /> : null}
                {t(isRestart ? 'console.providers.restart_login' : 'console.providers.start_login')}
              </Button>
            ) : null}
            {showingBrowserPaste ? (
              <Button
                aria-busy={submitting}
                type="submit"
                disabled={submitting || !loginContext}
                incomplete={!callbackURL.trim() && !submitting && Boolean(loginContext)}>
                {submitting ? <Spinner aria-hidden data-icon="inline-start" /> : null}
                {t('console.providers.complete_login')}
              </Button>
            ) : null}
          </DialogFooter>
        </form>
      </DialogContent>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </Dialog>
  )
}

function textValue(value: unknown): string {
  return typeof value === 'string' ? value : ''
}
