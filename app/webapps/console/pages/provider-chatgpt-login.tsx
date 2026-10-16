import { recordValue } from '@agentbull/active-support'
import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Textarea,
  toast
} from '@ankole/uikit'
import { RiExternalLinkLine, RiLoaderLine } from '@remixicon/react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorCode, requestErrorDetails, requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAiGatewayProviderControllerCompleteChatgptBrowserLoginMutation as completeChatGPTBrowserLoginMutation,
  ankoleWebAiGatewayProviderControllerPollChatgptLoginMutation as pollChatGPTLoginMutation,
  ankoleWebAiGatewayProviderControllerStartChatgptLoginMutation as startChatGPTLoginMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AiGatewayCredentialPoolEntry as AIGatewayCredentialPoolEntry,
  AiGatewayProviderItem as AIGatewayProviderItem
} from '../api/generated/types.gen'
import { DiscardConfirmDialog, LabeledField, ReadOnlyValue, useDialogDiscardGuard } from '../console-form'

type LoginPayload = Record<string, unknown>

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
function chatGPTLoginErrorText(error: unknown, t: (key: string, values?: Record<string, string>) => string): string {
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
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [login, setLogin] = useState<LoginPayload>()
  const [callbackURL, setCallbackURL] = useState('')
  const [validationError, setValidationError] = useState<string>()

  const finish = () => {
    toast.success(t('console.providers.chatgpt_login_complete'))
    onOpenChange(false)
  }
  const start = useMutation({
    meta: { invalidates: false },
    ...startChatGPTLoginMutation(),
    onSuccess: response => setLogin(recordValue(response) ?? undefined)
  })
  const poll = useMutation({
    meta: { invalidates: false },
    ...pollChatGPTLoginMutation(),
    onSuccess: response => {
      const update = recordValue(response) ?? {}
      if (update.status === 'complete') {
        void queryClient.invalidateQueries()
        finish()
      } else {
        setLogin(current => ({ ...current, ...update }))
      }
    }
  })
  const complete = useMutation({
    ...completeChatGPTBrowserLoginMutation(),
    onSuccess: finish
  })

  useEffect(() => {
    if (!open) return
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    setLogin(undefined)
    setCallbackURL('')
    setValidationError(undefined)
    start.reset()
    poll.reset()
    complete.reset()
  }, [entry, open])

  const mode = textValue(login?.mode)
  const status = textValue(login?.status)
  const loginContext = recordValue(login?.login_context)
  const retryAfter = numberValue(login?.retry_after) ?? numberValue(login?.interval) ?? 5

  useEffect(() => {
    if (!open || mode !== 'device' || status === 'complete' || !loginContext || poll.isPending) return
    const timer = window.setTimeout(() => {
      poll.mutate({
        body: { login_context: loginContext },
        path: { provider_id: provider.provider_id }
      })
    }, retryAfter * 1_000)
    return () => window.clearTimeout(timer)
    // `poll` itself is a fresh object every render; depending on it would clear
    // and restart the countdown on every re-render. `mutate` and `isPending`
    // are the stable parts this effect actually uses.
  }, [loginContext, mode, open, poll.isPending, poll.mutate, provider.provider_id, retryAfter, status])

  const startLogin = () => {
    if (!label.trim()) {
      setValidationError(t('console.providers.credential_label_required'))
      return
    }
    setValidationError(undefined)
    start.mutate({
      body: {
        id: entry?.id,
        label: label.trim() || entry?.label || undefined,
        priority: Number.parseInt(priority, 10) || 0
      },
      path: { provider_id: provider.provider_id }
    })
  }
  const completeBrowserLogin = () => {
    if (!callbackURL.trim()) {
      setValidationError(
        t('common.field_required', {
          field: t('console.providers.callback_url')
        })
      )
      return
    }
    if (!loginContext) return
    setValidationError(undefined)
    complete.mutate({
      body: { login_context: loginContext, callback_url: callbackURL.trim() },
      path: { provider_id: provider.provider_id }
    })
  }
  const error = validationError ?? start.error ?? poll.error ?? complete.error
  const pending = start.isPending || poll.isPending || complete.isPending
  const dirty =
    Boolean(login) ||
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    callbackURL.trim() !== ''
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending, onOpenChange })

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!pending}>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            if (!login) startLogin()
            else if (mode === 'browser_paste') completeBrowserLogin()
          }}>
          <DialogHeader>
            <DialogTitle>
              {entry ? t('console.providers.reauthenticate') : t('console.providers.add_chatgpt_account')}
            </DialogTitle>
            <DialogDescription>{t('console.providers.chatgpt_login_description')}</DialogDescription>
          </DialogHeader>

          <div className="grid gap-4">
            {error ? (
              <p className="text-sm text-destructive-foreground" aria-live="assertive">
                {chatGPTLoginErrorText(error, t)}
              </p>
            ) : null}
            {!login ? (
              <>
                <LabeledField label={t('console.providers.credential_label')} required>
                  <Input
                    value={label}
                    onChange={event => {
                      setLabel(event.target.value)
                      setValidationError(undefined)
                    }}
                  />
                </LabeledField>
                <LabeledField label={t('console.providers.priority')}>
                  <Input type="number" step={1} value={priority} onChange={event => setPriority(event.target.value)} />
                </LabeledField>
              </>
            ) : null}

            {mode === 'device' ? (
              <div className="grid gap-4 border border-border bg-muted/30 p-4">
                <p className="text-sm">{t('console.providers.device_login_instructions')}</p>
                <a
                  className="link inline-flex items-center gap-1 text-sm"
                  href={textValue(login?.verification_url)}
                  target="_blank"
                  rel="noreferrer">
                  {textValue(login?.verification_url)}
                  <RiExternalLinkLine className="size-4" aria-hidden />
                </a>
                <ReadOnlyValue mono>{textValue(login?.user_code)}</ReadOnlyValue>
                <p className="text-xs text-muted-foreground">
                  {poll.isPending
                    ? t('console.providers.device_login_polling')
                    : t('console.providers.device_login_waiting', { seconds: retryAfter })}
                </p>
              </div>
            ) : null}

            {mode === 'browser_paste' ? (
              <div className="grid gap-4 border border-border bg-muted/30 p-4">
                <p className="text-sm">{t('console.providers.browser_login_instructions')}</p>
                <a
                  className="link inline-flex items-center gap-1 text-sm"
                  href={textValue(login?.authorization_url)}
                  target="_blank"
                  rel="noreferrer">
                  {t('console.providers.open_authorization')}
                  <RiExternalLinkLine className="size-4" aria-hidden />
                </a>
                <LabeledField label={t('console.providers.callback_url')} required>
                  <Textarea
                    className="min-h-24 font-mono text-xs"
                    value={callbackURL}
                    onChange={event => {
                      setCallbackURL(event.target.value)
                      setValidationError(undefined)
                    }}
                  />
                </LabeledField>
              </div>
            ) : null}
          </div>

          <DialogFooter>
            <Button type="button" variant="ghost" disabled={pending} onClick={() => guard.requestOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            {!login ? (
              <Button aria-busy={pending} type="submit" disabled={pending} incomplete={!label.trim() && !pending}>
                {pending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
                {t('console.providers.start_login')}
              </Button>
            ) : null}
            {mode === 'browser_paste' ? (
              <Button
                aria-busy={pending}
                type="submit"
                disabled={pending || !loginContext}
                incomplete={!callbackURL.trim() && !pending && Boolean(loginContext)}>
                {pending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
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

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}
