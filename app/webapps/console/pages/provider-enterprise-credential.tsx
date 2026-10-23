import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  toast
} from '@ankole/uikit'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../../common/request-errors'
import { ankoleWebAiGatewayProviderControllerAddChatgptEnterpriseCredentialMutation as addChatGPTEnterpriseCredentialMutation } from '../api/generated/@tanstack/react-query.gen'
import { DiscardConfirmDialog, LabeledField, SaveButton, useDialogDiscardGuard } from '../console-form'
import { EncryptedValueInput } from '../encrypted-value-input'
import type { AIGatewayProviderItem, AIGatewayCredentialPoolEntry } from '../state/provider-settings'

export function EnterpriseCredentialDialog({
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
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [accessToken, setAccessToken] = useState('')
  const [accountID, setAccountID] = useState('')
  const [planType, setPlanType] = useState('')
  const [email, setEmail] = useState('')
  const [validationError, setValidationError] = useState<string>()
  const labelInput = useRef<HTMLInputElement>(null)
  const accessTokenInput = useRef<HTMLInputElement>(null)
  const accountIDInput = useRef<HTMLInputElement>(null)

  const save = useMutation({
    ...addChatGPTEnterpriseCredentialMutation(),
    onSuccess: () => {
      toast.success(t('console.providers.enterprise_token_saved'))
      onOpenChange(false)
    }
  })

  useEffect(() => {
    if (!open) return
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    setAccessToken('')
    setAccountID(entry?.account_id ?? '')
    setPlanType(entry?.plan_type ?? '')
    setEmail(entry?.email ?? '')
    setValidationError(undefined)
    save.reset()
  }, [entry, open])

  const submit = () => {
    const requiredField = [
      { field: t('console.providers.credential_label'), input: labelInput, value: label.trim() },
      { field: t('console.providers.access_token'), input: accessTokenInput, value: accessToken.trim() },
      { field: t('console.providers.account_id'), input: accountIDInput, value: accountID.trim() }
    ].find(item => !item.value)
    if (requiredField) {
      setValidationError(t('common.field_required', { field: requiredField.field }))
      requiredField.input.current?.focus()
      return
    }

    setValidationError(undefined)
    save.mutate({
      body: {
        id: entry?.id,
        label: label.trim() || undefined,
        priority: Number.parseInt(priority, 10) || 0,
        access_token: accessToken.trim(),
        account_id: accountID.trim(),
        plan_type: planType.trim() || undefined,
        email: email.trim() || undefined
      },
      path: { provider_id: provider.provider_id }
    })
  }
  const incomplete = !label.trim() || !accessToken.trim() || !accountID.trim()
  const dirty =
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    accessToken.trim() !== '' ||
    accountID !== (entry?.account_id ?? '') ||
    planType !== (entry?.plan_type ?? '') ||
    email !== (entry?.email ?? '')
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending: save.isPending, onOpenChange })

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!save.isPending}>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            submit()
          }}>
          <DialogHeader>
            <DialogTitle>
              {entry ? t('console.providers.reauthenticate') : t('console.providers.add_enterprise_token')}
            </DialogTitle>
            <DialogDescription>{t('console.providers.enterprise_token_description')}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            {validationError || save.error ? (
              <p className="text-sm text-destructive-foreground" aria-live="assertive">
                {validationError ?? requestErrorMessage(save.error)}
              </p>
            ) : null}
            <LabeledField label={t('console.providers.credential_label')} required>
              <Input
                ref={labelInput}
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
            <LabeledField label={t('console.providers.access_token')} required>
              <EncryptedValueInput
                ref={accessTokenInput}
                revealLabel={t('console.aria.reveal_secret')}
                value={accessToken}
                onChange={event => {
                  setAccessToken(event.target.value)
                  setValidationError(undefined)
                }}
              />
            </LabeledField>
            <LabeledField label={t('console.providers.account_id')} required>
              <Input
                ref={accountIDInput}
                value={accountID}
                onChange={event => {
                  setAccountID(event.target.value)
                  setValidationError(undefined)
                }}
              />
            </LabeledField>
            <LabeledField label={t('console.providers.plan_type')}>
              <Input value={planType} onChange={event => setPlanType(event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.providers.email')}>
              <Input type="email" value={email} onChange={event => setEmail(event.target.value)} />
            </LabeledField>
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="ghost"
              disabled={save.isPending}
              onClick={() => guard.requestOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            <SaveButton
              type="submit"
              disabled={save.isPending}
              incomplete={incomplete && !save.isPending}
              loading={save.isPending}>
              {t('common.save')}
            </SaveButton>
          </DialogFooter>
        </form>
      </DialogContent>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </Dialog>
  )
}
