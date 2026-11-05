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
import {
  addChatgptEnterpriseCredentialMutation as addChatGPTEnterpriseCredentialMutation,
  putAiGatewayCredentialMutation as putCredentialMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import { DiscardConfirmDialog, LabeledField, SaveButton, useDialogDiscardGuard } from '../console-form'
import { ENCRYPTED_VALUE_MASK, EncryptedValueInput, isEncryptedValueMask } from '../encrypted-value-input'
import {
  entryHasSecretField,
  type AIGatewayProviderItem,
  type AIGatewayCredentialPoolEntry
} from '../state/provider-settings'
import { useCredentialDecryption } from './use-credential-decryption'

export function EnterpriseCredentialDialog({
  entry,
  onCredentialSaved,
  onOpenChange,
  open,
  provider
}: {
  entry: AIGatewayCredentialPoolEntry | null | undefined
  onCredentialSaved?: (credentialID: string) => void
  onOpenChange: (open: boolean) => void
  open: boolean
  provider: AIGatewayProviderItem
}) {
  const { t } = useTranslation()
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [accessToken, setAccessToken] = useState('')
  const [baselineAccessToken, setBaselineAccessToken] = useState('')
  const [tokenRevealed, setTokenRevealed] = useState(false)
  const [accountID, setAccountID] = useState('')
  const [planType, setPlanType] = useState('')
  const [email, setEmail] = useState('')
  const [validationError, setValidationError] = useState<string>()
  const labelInput = useRef<HTMLInputElement>(null)
  const accessTokenInput = useRef<HTMLInputElement>(null)
  const accountIDInput = useRef<HTMLInputElement>(null)

  const hasStoredToken = Boolean(entry && !entry.reauth_required && entryHasSecretField(entry, 'access_token'))

  const finish = () => {
    if (entry) onCredentialSaved?.(entry.id)
    toast.success(t('console.providers.enterprise_token_saved'))
    onOpenChange(false)
  }
  const save = useMutation({
    ...addChatGPTEnterpriseCredentialMutation(),
    onSuccess: finish
  })
  const updateMetadata = useMutation({
    ...putCredentialMutation(),
    onSuccess: finish
  })
  const decrypt = useCredentialDecryption()

  useEffect(() => {
    setTokenRevealed(false)
    decrypt.reset()
    if (!open) {
      setAccessToken('')
      setBaselineAccessToken('')
      return
    }
    const seededToken =
      entry && !entry.reauth_required && entryHasSecretField(entry, 'access_token') ? ENCRYPTED_VALUE_MASK : ''
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    setAccessToken(seededToken)
    setBaselineAccessToken(seededToken)
    setAccountID(entry?.account_id ?? '')
    setPlanType(entry?.plan_type ?? '')
    setEmail(entry?.email ?? '')
    setValidationError(undefined)
    save.reset()
    updateMetadata.reset()
  }, [decrypt.reset, entry?.id, entry?.reauth_required, open])

  const revealAccessToken = () => {
    if (!entry) return
    void decrypt.reveal({
      providerID: provider.provider_id,
      credentialID: entry.id,
      fieldKey: 'access_token',
      onDecrypted: value => {
        const decrypted = value ?? ''
        setAccessToken(current => (isEncryptedValueMask(current) ? decrypted : current))
        setBaselineAccessToken(current => (isEncryptedValueMask(current) ? decrypted : current))
        setTokenRevealed(true)
      }
    })
  }

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
    if (entry && baselineAccessToken !== '' && accessToken === baselineAccessToken) {
      const credential: Record<string, unknown> = {
        label: label.trim(),
        priority: Number.parseInt(priority, 10) || 0
      }
      if (accountID.trim() !== (entry.account_id ?? '')) credential.account_id = accountID.trim()
      if (planType.trim() !== (entry.plan_type ?? '')) credential.plan_type = planType.trim() || null
      if (email.trim() !== (entry.email ?? '')) credential.email = email.trim() || null
      updateMetadata.mutate({
        body: {
          data: {
            id: provider.id,
            type: 'ai_gateway_provider',
            attributes: { credential }
          }
        },
        path: { provider_id: provider.provider_id, credential_id: entry.id }
      })
      return
    }

    save.mutate({
      body: {
        data: {
          credential: {
            id: entry?.id,
            label: label.trim() || undefined,
            priority: Number.parseInt(priority, 10) || 0,
            access_token: accessToken.trim(),
            account_id: accountID.trim(),
            plan_type: planType.trim() || undefined,
            email: email.trim() || undefined
          }
        }
      },
      path: { provider_id: provider.provider_id }
    })
  }
  const pending = save.isPending || updateMetadata.isPending
  const requestError = save.error ?? updateMetadata.error ?? decrypt.error
  const incomplete = !label.trim() || !accessToken.trim() || !accountID.trim()
  const dirty =
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    accessToken !== baselineAccessToken ||
    accountID !== (entry?.account_id ?? '') ||
    planType !== (entry?.plan_type ?? '') ||
    email !== (entry?.email ?? '')
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending, onOpenChange })
  const accessTokenLabel = t('console.providers.access_token')
  const dialogTitle = !entry
    ? t('console.providers.add_enterprise_token')
    : entry.reauth_required
      ? t('console.providers.reauthenticate')
      : t('console.providers.edit_credential')

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!pending}>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            submit()
          }}>
          <DialogHeader>
            <DialogTitle>{dialogTitle}</DialogTitle>
            <DialogDescription>{t('console.providers.enterprise_token_description')}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            {validationError || requestError ? (
              <p className="text-sm text-destructive-foreground" aria-live="assertive">
                {validationError ?? requestErrorMessage(requestError)}
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
            <LabeledField
              label={accessTokenLabel}
              description={
                hasStoredToken ? t('console.providers.secret_value_hint') : t('console.providers.secret_hint')
              }
              required>
              <EncryptedValueInput
                ref={accessTokenInput}
                hideLabel={t('console.providers.hide_field', { field: accessTokenLabel })}
                revealLabel={t('console.providers.reveal_field', { field: accessTokenLabel })}
                revealed={tokenRevealed}
                revealing={decrypt.isRevealing('access_token')}
                value={accessToken}
                onChange={event => {
                  decrypt.cancelTarget('access_token')
                  setAccessToken(event.target.value)
                  setValidationError(undefined)
                }}
                onReveal={hasStoredToken ? revealAccessToken : undefined}
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
            <Button type="button" variant="ghost" disabled={pending} onClick={() => guard.requestOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            <SaveButton type="submit" disabled={pending} incomplete={incomplete && !pending} loading={pending}>
              {t('common.save')}
            </SaveButton>
          </DialogFooter>
        </form>
      </DialogContent>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </Dialog>
  )
}
