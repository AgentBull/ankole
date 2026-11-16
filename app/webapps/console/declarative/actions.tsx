import {
  Alert,
  AlertDescription,
  AlertTitle,
  Button,
  CopyButton,
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle
} from '@ankole/uikit'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { DeclarativeFields } from './fields'
import {
  withFieldDefaults,
  formatIdentifierLabel,
  serializeDeclarativeFields,
  type DeclarativeRecord
} from './transport'
import type { DeclarativeSurfaceDescriptor } from './types'

export interface DeclarativeActionTriggerProps {
  readonly surface: DeclarativeSurfaceDescriptor
  readonly label?: ReactNode
  readonly disabled?: boolean
  readonly startOpen?: boolean
  readonly i18nPrefix?: string
  readonly payload?: Readonly<Record<string, unknown>>
  readonly onDismiss?: () => void
  readonly onExecute?: (
    surface: DeclarativeSurfaceDescriptor,
    serializedPayload: Record<string, unknown>
  ) => readonly DeclarativeRecord[] | void | Promise<readonly DeclarativeRecord[] | void>
}

export function DeclarativeActionTrigger({
  surface,
  label,
  disabled = false,
  startOpen = false,
  i18nPrefix = 'console',
  payload = {},
  onDismiss,
  onExecute
}: DeclarativeActionTriggerProps) {
  const { t } = useTranslation()
  const title = label ?? t(surface.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })
  const [open, setOpen] = useState(startOpen)
  const [draft, setDraft] = useState<Record<string, unknown>>({})
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [revealedSecret, setRevealedSecret] = useState<string | null>(null)

  const mergedValues = withFieldDefaults(surface.fields, { ...payload, ...draft })
  const visibleFields = surface.fields.filter(field => !('id' in payload && field.name === 'id'))

  return (
    <>
      {!startOpen && (
        <Button
          disabled={disabled || !onExecute}
          size="sm"
          type="button"
          variant={surface.method === 'DELETE' ? 'outline' : 'outline'}
          onClick={() => {
            setDraft({})
            setError(null)
            setRevealedSecret(null)
            setOpen(true)
          }}>
          {title}
        </Button>
      )}
      <Dialog
        open={open}
        onOpenChange={next => {
          setOpen(next)
          if (!next) {
            setRevealedSecret(null)
            onDismiss?.()
          }
        }}>
        {open && (
          <DialogContent
            className="flex max-h-[85vh] flex-col gap-4 overflow-hidden sm:max-w-2xl"
            closeLabel={t('common.close', { defaultValue: 'Close' })}>
            <DialogHeader>
              <DialogTitle>{title}</DialogTitle>
            </DialogHeader>

            {revealedSecret ? (
              <div className="grid gap-4">
                <Alert variant="warning">
                  <AlertTitle>
                    {t(`${i18nPrefix}.ui.secret_created`, { defaultValue: 'Store this secret now' })}
                  </AlertTitle>
                  <AlertDescription>
                    <p className="mb-2 text-xs text-muted-foreground">
                      {t(`${i18nPrefix}.ui.secret_once`, {
                        defaultValue: 'This secret is displayed only once and cannot be retrieved again.'
                      })}
                    </p>
                    <div className="flex items-center gap-2">
                      <code className="flex-1 overflow-x-auto rounded-control border border-border bg-muted px-2.5 py-1.5 font-mono text-xs">
                        {revealedSecret}
                      </code>
                      <CopyButton
                        copiedLabel={t('common.copied', { defaultValue: 'Copied' })}
                        label={t('common.copy', { defaultValue: 'Copy' })}
                        value={revealedSecret}
                      />
                    </div>
                  </AlertDescription>
                </Alert>
                <div className="flex justify-end border-t border-border pt-3">
                  <Button
                    size="sm"
                    type="button"
                    onClick={() => {
                      setRevealedSecret(null)
                      setOpen(false)
                      onDismiss?.()
                    }}>
                    {t('common.close', { defaultValue: 'Close' })}
                  </Button>
                </div>
              </div>
            ) : (
              <form
                className="flex min-h-0 flex-1 flex-col gap-4"
                noValidate
                onSubmit={async event => {
                  event.preventDefault()
                  const form = event.currentTarget
                  if (!form.reportValidity()) return
                  setPending(true)
                  setError(null)
                  try {
                    const serialized = serializeDeclarativeFields(surface, mergedValues, payload.id)
                    const result = await onExecute?.(surface, serialized)
                    const secretValue =
                      surface.secretField && Array.isArray(result) ? result[0]?.[surface.secretField] : undefined
                    setDraft({})
                    if (typeof secretValue === 'string' && secretValue) {
                      setRevealedSecret(secretValue)
                    } else {
                      setOpen(false)
                      onDismiss?.()
                    }
                  } catch (failure) {
                    setError(failure instanceof Error ? failure.message : String(failure))
                  } finally {
                    setPending(false)
                  }
                }}>
                <div className="min-h-0 flex-1 overflow-y-auto pr-1">
                  {surface.method === 'DELETE' && visibleFields.every(field => field.readOnly) ? (
                    <p className="text-sm text-muted-foreground">
                      {t(`${i18nPrefix}.ui.confirm_delete`, {
                        defaultValue: 'Are you sure you want to delete this item?'
                      })}
                    </p>
                  ) : (
                    <DeclarativeFields
                      draft={mergedValues}
                      fields={visibleFields}
                      i18nPrefix={i18nPrefix}
                      ruleSchema={surface.ruleSchema}
                      onChange={next =>
                        setDraft(Object.fromEntries(Object.entries(next).filter(([k, v]) => v !== payload[k])))
                      }
                    />
                  )}
                </div>

                {error ? (
                  <p className="text-sm text-destructive" role="alert">
                    {error}
                  </p>
                ) : null}

                <div className="flex justify-end gap-2 border-t border-border pt-3">
                  <Button
                    disabled={pending}
                    size="sm"
                    type="button"
                    variant="outline"
                    onClick={() => {
                      setOpen(false)
                      onDismiss?.()
                    }}>
                    {t('common.cancel', { defaultValue: 'Cancel' })}
                  </Button>
                  <Button
                    disabled={pending}
                    size="sm"
                    type="submit"
                    variant={surface.method === 'DELETE' ? 'destructive' : 'default'}>
                    {pending
                      ? t(`${i18nPrefix}.ui.submitting`, { defaultValue: 'Submitting...' })
                      : t(`${i18nPrefix}.ui.confirm`, { defaultValue: 'Confirm' })}
                  </Button>
                </div>
              </form>
            )}
          </DialogContent>
        )}
      </Dialog>
    </>
  )
}
