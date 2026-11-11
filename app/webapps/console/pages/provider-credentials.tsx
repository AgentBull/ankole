import { recordValue } from '@agentbull/active-support'
import {
  Badge,
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Spinner,
  toast
} from '@ankole/uikit'
import { AddRegular, ArrowClockwiseRegular, EyeOffRegular, EyeRegular } from '@ankole/uikit/icons'
import { useMutation } from '@tanstack/react-query'
import type { TFunction } from 'i18next'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../../common/request-errors'
import {
  addAiGatewayCredentialMutation as addCredentialMutation,
  deleteAiGatewayCredentialMutation as deleteCredentialMutation,
  putAiGatewayCredentialMutation as putCredentialMutation,
  putAiGatewayCredentialStrategyMutation as putCredentialStrategyMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import type { AIGatewayProviderKindItem, ProviderSetting } from '../state/provider-settings'
import {
  ConfirmDeleteButton,
  DiscardConfirmDialog,
  LabeledField,
  SaveButton,
  StatusIndicator,
  useDialogDiscardGuard
} from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, isEncryptedValueMask } from '../encrypted-value-input'
import {
  aiGatewayProvider,
  buildSettingOptions,
  credentialSettings,
  entryHasSecretField,
  humanizeKey,
  secretCredentialSettings,
  settingValidationMessage
} from '../state/provider-settings'
import { ProviderSettingField, providerSettingLabel } from './provider-setting-field'
import { useCredentialDecryption } from './use-credential-decryption'

import { ChatGPTLoginDialog } from './provider-chatgpt-login'
import { EnterpriseCredentialDialog } from './provider-enterprise-credential'
import type { AIGatewayProviderItem, AIGatewayCredentialPoolEntry } from '../state/provider-settings'

type CredentialStrategy = AIGatewayProviderItem['credential_pool']['strategy']
const credentialStrategies = [
  'fill_first',
  'round_robin',
  'least_used',
  'random'
] as const satisfies readonly CredentialStrategy[]

export function CredentialPoolEditor({
  provider,
  providerKind
}: {
  provider: AIGatewayProviderItem
  providerKind: AIGatewayProviderKindItem
}) {
  const { t } = useTranslation()
  const [credentialEditor, setCredentialEditor] = useState<AIGatewayCredentialPoolEntry | null | undefined>()
  const [chatGPTLoginEntry, setChatGPTLoginEntry] = useState<AIGatewayCredentialPoolEntry | null | undefined>()
  const [enterpriseEntry, setEnterpriseEntry] = useState<AIGatewayCredentialPoolEntry | null | undefined>()
  const [revealed, setRevealed] = useState<Record<string, string>>({})
  const revealTimers = useRef<Record<string, number>>({})
  const decryptCardField = useCredentialDecryption()
  const isChatGPT = provider.provider_kind === 'chatgpt_subscription'
  const secretSettings = useMemo(() => secretCredentialSettings(providerKind), [providerKind])

  const hideRevealedSlot = (slotKey: string) => {
    decryptCardField.cancelTarget(slotKey)
    window.clearTimeout(revealTimers.current[slotKey])
    delete revealTimers.current[slotKey]
    setRevealed(current => {
      if (!(slotKey in current)) return current
      const next = { ...current }
      delete next[slotKey]
      return next
    })
  }

  const clearEntryReveals = (credentialID: string) => {
    const prefix = `${credentialID}:`
    decryptCardField.cancelPrefix(prefix)
    for (const slotKey of Object.keys(revealTimers.current)) {
      if (slotKey.startsWith(prefix)) {
        window.clearTimeout(revealTimers.current[slotKey])
        delete revealTimers.current[slotKey]
      }
    }
    setRevealed(current => {
      const next = Object.fromEntries(Object.entries(current).filter(([key]) => !key.startsWith(prefix)))
      return Object.keys(next).length === Object.keys(current).length ? current : next
    })
  }

  useEffect(() => {
    const remaskAll = () => {
      decryptCardField.reset()
      for (const timeout of Object.values(revealTimers.current)) window.clearTimeout(timeout)
      revealTimers.current = {}
      setRevealed({})
    }
    remaskAll()
    window.addEventListener('blur', remaskAll)
    return () => {
      window.removeEventListener('blur', remaskAll)
      for (const timeout of Object.values(revealTimers.current)) window.clearTimeout(timeout)
      revealTimers.current = {}
    }
  }, [decryptCardField.reset, provider.provider_id])

  const setStrategy = useMutation({
    ...putCredentialStrategyMutation(),
    onSuccess: response => {
      toast.success(
        t('console.providers.strategy_saved', {
          strategy: credentialStrategyLabel(t, aiGatewayProvider(response).credential_pool.strategy)
        })
      )
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const updateCredential = useMutation({
    ...putCredentialMutation(),
    onSuccess: (_response, variables) => {
      clearEntryReveals(variables.path.credential_id)
      toast.success(t('console.providers.credential_saved'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeCredential = useMutation({
    ...deleteCredentialMutation(),
    onSuccess: (_response, variables) => {
      clearEntryReveals(variables.path.credential_id)
      toast.success(t('console.providers.credential_deleted'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const revealEntryField = (credentialID: string, fieldKey: string) => {
    const slotKey = `${credentialID}:${fieldKey}`
    void decryptCardField.reveal({
      providerID: provider.provider_id,
      credentialID,
      fieldKey,
      targetKey: slotKey,
      onDecrypted: value => {
        if (value === undefined) return
        setRevealed(current => ({ ...current, [slotKey]: value }))
        window.clearTimeout(revealTimers.current[slotKey])
        revealTimers.current[slotKey] = window.setTimeout(() => hideRevealedSlot(slotKey), 30_000)
      },
      onError: error => toast.error(requestErrorMessage(error))
    })
  }

  const changeAvailability = (entry: AIGatewayCredentialPoolEntry) => {
    updateCredential.mutate({
      body: {
        data: {
          id: provider.id,
          type: 'ai_gateway_provider',
          attributes: { credential: { disabled_at: entry.status === 'disabled' ? null : new Date().toISOString() } }
        }
      },
      path: { provider_id: provider.provider_id, credential_id: entry.id }
    })
  }

  return (
    <section className="grid gap-5 border border-border bg-card p-5 md:p-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="grid gap-1">
          <h3 className="title-section">{t('console.providers.pool_title')}</h3>
          <p className="max-w-2xl text-sm text-muted-foreground">{t('console.providers.pool_description')}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {isChatGPT ? (
            <>
              <Button size="sm" type="button" onClick={() => setChatGPTLoginEntry(null)}>
                <AddRegular data-icon="inline-start" />
                {t('console.providers.add_chatgpt_account')}
              </Button>
              <Button size="sm" type="button" variant="outline" onClick={() => setEnterpriseEntry(null)}>
                <AddRegular data-icon="inline-start" />
                {t('console.providers.add_enterprise_token')}
              </Button>
            </>
          ) : (
            <Button size="sm" type="button" onClick={() => setCredentialEditor(null)}>
              <AddRegular data-icon="inline-start" />
              {t('console.providers.add_credential')}
            </Button>
          )}
        </div>
      </div>

      <LabeledField label={t('console.providers.strategy')} description={t('console.providers.strategy_hint')}>
        <Select
          value={provider.credential_pool.strategy}
          disabled={setStrategy.isPending}
          onValueChange={value =>
            setStrategy.mutate({
              body: {
                data: {
                  id: provider.id,
                  type: 'ai_gateway_provider',
                  attributes: { strategy: String(value) as CredentialStrategy }
                }
              },
              path: { provider_id: provider.provider_id }
            })
          }>
          <SelectTrigger className="w-full md:max-w-sm">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {credentialStrategies.map(strategy => (
              <SelectItem key={strategy} value={strategy}>
                {credentialStrategyLabel(t, strategy)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </LabeledField>

      {provider.credential_pool.entries.length === 0 ? (
        <div className="border border-dashed border-border p-6 text-sm text-muted-foreground">
          {t('console.providers.pool_empty')}
        </div>
      ) : (
        <div className="grid gap-3">
          {provider.credential_pool.entries.map(entry => (
            <article key={entry.id} className="grid gap-4 border border-border bg-background p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="grid gap-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h4 className="font-medium">{entry.label}</h4>
                    <StatusIndicator tone={credentialStatusTone(entry.status)}>
                      {t(`console.providers.credential_status_${entry.status}`)}
                    </StatusIndicator>
                    {entry.reauth_required ? (
                      <Badge variant="warning">{t('console.providers.reauth_required')}</Badge>
                    ) : null}
                  </div>
                  <div className="flex flex-wrap gap-x-4 gap-y-1 font-mono text-xs text-muted-foreground">
                    <span>{entry.id}</span>
                    <span>{t('console.providers.priority_value', { priority: entry.priority })}</span>
                    <span>{credentialSourceLabel(t, entry.source)}</span>
                  </div>
                </div>
                <div className="flex flex-wrap gap-2">
                  {entry.reauth_required && isChatGPT ? (
                    <Button
                      size="xs"
                      type="button"
                      variant="outline"
                      onClick={() =>
                        entry.auth_type === 'enterprise_access_token'
                          ? setEnterpriseEntry(entry)
                          : setChatGPTLoginEntry(entry)
                      }>
                      <ArrowClockwiseRegular data-icon="inline-start" />
                      {t('console.providers.reauthenticate')}
                    </Button>
                  ) : null}
                  <Button
                    size="xs"
                    type="button"
                    variant="outline"
                    onClick={() =>
                      isChatGPT && entry.auth_type === 'enterprise_access_token'
                        ? setEnterpriseEntry(entry)
                        : setCredentialEditor(entry)
                    }>
                    {t('common.edit')}
                  </Button>
                  <Button
                    size="xs"
                    type="button"
                    variant="outline"
                    disabled={updateCredential.isPending}
                    onClick={() => changeAvailability(entry)}>
                    {entry.status === 'disabled' ? t('common.enable') : t('common.disable')}
                  </Button>
                  <ConfirmDeleteButton
                    pending={removeCredential.isPending}
                    confirm={{
                      title: t('console.providers.delete_credential_title'),
                      description: t('console.providers.delete_credential_description', { label: entry.label }),
                      confirmLabel: t('common.delete')
                    }}
                    onConfirm={() =>
                      removeCredential.mutate({
                        path: { provider_id: provider.provider_id, credential_id: entry.id }
                      })
                    }
                  />
                </div>
              </div>

              <dl className="grid gap-3 text-sm md:grid-cols-2">
                {secretSettings
                  .filter(setting => entryHasSecretField(entry, setting.key))
                  .map(setting => {
                    const fieldLabel = providerSettingLabel(t, setting.key)
                    const slotKey = `${entry.id}:${setting.key}`
                    const revealedValue = revealed[slotKey]
                    const actionLabel =
                      revealedValue === undefined
                        ? t('console.providers.reveal_field', { field: fieldLabel })
                        : t('console.providers.hide_field', { field: fieldLabel })
                    return (
                      <CredentialSecretFact
                        key={setting.key}
                        actionLabel={actionLabel}
                        label={fieldLabel}
                        revealedValue={revealedValue}
                        revealing={decryptCardField.isRevealing(slotKey)}
                        onToggle={() =>
                          revealedValue === undefined
                            ? revealEntryField(entry.id, setting.key)
                            : hideRevealedSlot(slotKey)
                        }
                      />
                    )
                  })}
                <CredentialFact label={t('console.providers.account_id')} value={entry.account_id} />
                <CredentialFact label={t('console.providers.email')} value={entry.email} />
                <CredentialFact label={t('console.providers.plan_type')} value={entry.plan_type} />
                <CredentialFact
                  label={t('console.providers.auth_type')}
                  value={entry.auth_type ? humanizeKey(entry.auth_type) : undefined}
                />
                <CredentialFact label={t('console.providers.request_count')} value={String(entry.request_count ?? 0)} />
                <CredentialFact
                  label={t('console.providers.token_usage')}
                  value={formatCredentialUsage(t, entry.usage)}
                />
                <CredentialFact
                  label={t('console.providers.last_selected_at')}
                  value={entry.last_selected_at ? formatConsoleDate(entry.last_selected_at) : undefined}
                />
                <CredentialFact
                  label={t('console.providers.retry_at')}
                  value={entry.retry_at ? formatConsoleDate(entry.retry_at) : undefined}
                />
                <CredentialFact
                  label={t('console.providers.last_refresh')}
                  value={entry.last_refresh ? formatConsoleDate(entry.last_refresh) : undefined}
                />
              </dl>

              <CredentialDiagnostics
                label={t('console.providers.rate_limits')}
                value={formatRateLimits(entry.rate_limits)}
              />

              {entry.last_error_code || entry.last_error_reason || entry.last_error_message ? (
                <div className="grid gap-1 border-l-2 border-warning px-3 text-xs">
                  <span className="font-mono">
                    {[entry.provider_status, entry.last_error_code, entry.last_error_reason]
                      .filter(Boolean)
                      .join(' · ')}
                  </span>
                  {entry.last_error_message ? (
                    <span className="text-muted-foreground">{entry.last_error_message}</span>
                  ) : null}
                </div>
              ) : null}
            </article>
          ))}
        </div>
      )}

      <CredentialEditorDialog
        entry={credentialEditor}
        provider={provider}
        providerKind={providerKind}
        open={credentialEditor !== undefined}
        onCredentialSaved={clearEntryReveals}
        onOpenChange={open => !open && setCredentialEditor(undefined)}
      />
      <ChatGPTLoginDialog
        entry={chatGPTLoginEntry}
        provider={provider}
        open={chatGPTLoginEntry !== undefined}
        onOpenChange={open => {
          if (!open && chatGPTLoginEntry) clearEntryReveals(chatGPTLoginEntry.id)
          if (!open) setChatGPTLoginEntry(undefined)
        }}
      />
      <EnterpriseCredentialDialog
        entry={enterpriseEntry}
        provider={provider}
        open={enterpriseEntry !== undefined}
        onCredentialSaved={clearEntryReveals}
        onOpenChange={open => !open && setEnterpriseEntry(undefined)}
      />
    </section>
  )
}

function initialSecretDrafts(
  entry: AIGatewayCredentialPoolEntry | null | undefined,
  settings: ProviderSetting[]
): Record<string, string> {
  if (!entry) return {}
  const drafts: Record<string, string> = {}
  for (const setting of settings) {
    if (setting.encrypted && entryHasSecretField(entry, setting.key)) {
      drafts[setting.key] = ENCRYPTED_VALUE_MASK
    }
  }
  return drafts
}

function buildCredentialEditDrafts(
  entry: AIGatewayCredentialPoolEntry | null | undefined,
  settings: ProviderSetting[],
  values: Record<string, string>,
  baselineValues: Record<string, string>
): { drafts: Record<string, string>; clearedOptional: Record<string, null> } {
  if (!entry) return { drafts: values, clearedOptional: {} }
  const drafts: Record<string, string> = {}
  const clearedOptional: Record<string, null> = {}
  for (const setting of settings) {
    const current = values[setting.key] ?? ''
    const baseline = baselineValues[setting.key] ?? ''
    if (setting.encrypted && current === baseline) continue
    if (setting.encrypted && current.trim() === '' && baseline !== '' && !setting.required) {
      clearedOptional[setting.key] = null
      continue
    }
    drafts[setting.key] = current
  }
  return { drafts, clearedOptional }
}

function missingRequiredSecretSetting(
  entry: AIGatewayCredentialPoolEntry | null | undefined,
  settings: ProviderSetting[],
  values: Record<string, string>,
  baselineValues: Record<string, string>
): ProviderSetting | undefined {
  return settings.find(setting => {
    if (!setting.required) return false
    if (entry && setting.encrypted && (baselineValues[setting.key] ?? '') === '') return false
    return !(values[setting.key] ?? '').trim()
  })
}

function CredentialEditorDialog({
  entry,
  onCredentialSaved,
  onOpenChange,
  open,
  provider,
  providerKind
}: {
  entry: AIGatewayCredentialPoolEntry | null | undefined
  onCredentialSaved?: (credentialID: string) => void
  onOpenChange: (open: boolean) => void
  open: boolean
  provider: AIGatewayProviderItem
  providerKind: AIGatewayProviderKindItem
}) {
  const { t } = useTranslation()
  // ChatGPT OAuth entries hold tokens owned by the login flow, so only label
  // and priority are editable while stored tokens can be revealed read-only.
  const metadataOnly = provider.provider_kind === 'chatgpt_subscription'
  const settings = useMemo(() => (metadataOnly ? [] : credentialSettings(providerKind)), [metadataOnly, providerKind])
  const readOnlySecrets = useMemo(
    () =>
      metadataOnly && entry
        ? secretCredentialSettings(providerKind).filter(setting => entryHasSecretField(entry, setting.key))
        : [],
    [entry, metadataOnly, providerKind]
  )
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [values, setValues] = useState<Record<string, string>>({})
  const [baselineValues, setBaselineValues] = useState<Record<string, string>>({})
  const [revealedKeys, setRevealedKeys] = useState<Record<string, boolean>>({})
  const [validationError, setValidationError] = useState<string>()

  const finish = () => {
    if (entry) onCredentialSaved?.(entry.id)
    toast.success(t('console.providers.credential_saved'))
    onOpenChange(false)
  }
  const create = useMutation({
    ...addCredentialMutation(),
    onSuccess: finish
  })
  const update = useMutation({
    ...putCredentialMutation(),
    onSuccess: finish
  })
  const decrypt = useCredentialDecryption()

  useEffect(() => {
    setRevealedKeys({})
    decrypt.reset()
    if (!open) {
      setValues({})
      setBaselineValues({})
      return
    }
    const seeded = initialSecretDrafts(entry, [...settings, ...readOnlySecrets])
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    setValues(seeded)
    setBaselineValues(seeded)
    setValidationError(undefined)
    create.reset()
    update.reset()
  }, [decrypt.reset, entry?.id, open])

  const revealField = (fieldKey: string) => {
    if (!entry) return
    void decrypt.reveal({
      providerID: provider.provider_id,
      credentialID: entry.id,
      fieldKey,
      onDecrypted: value => {
        const decrypted = value ?? ''
        setValues(current =>
          isEncryptedValueMask(current[fieldKey] ?? '') ? { ...current, [fieldKey]: decrypted } : current
        )
        setBaselineValues(current =>
          isEncryptedValueMask(current[fieldKey] ?? '') ? { ...current, [fieldKey]: decrypted } : current
        )
        setRevealedKeys(current => ({ ...current, [fieldKey]: true }))
      }
    })
  }

  const submit = () => {
    setValidationError(undefined)
    if (!label.trim()) {
      setValidationError(t('console.providers.credential_label_required'))
      return
    }
    const missing = missingRequiredSecretSetting(entry, settings, values, baselineValues)
    if (missing) {
      setValidationError(settingValidationMessage(providerSettingLabel(t, missing.key), 'required'))
      return
    }

    const { drafts, clearedOptional } = buildCredentialEditDrafts(entry, settings, values, baselineValues)
    const built = buildSettingOptions(settings, drafts, settingValidationMessage, key => providerSettingLabel(t, key))
    if (!built.ok) {
      setValidationError(built.error)
      return
    }
    const body = {
      label: label.trim(),
      priority: Number.parseInt(priority, 10) || 0,
      ...clearedOptional,
      ...built.value
    }

    if (entry) {
      update.mutate({
        body: { data: { id: provider.id, type: 'ai_gateway_provider', attributes: { credential: body } } },
        path: { provider_id: provider.provider_id, credential_id: entry.id }
      })
    } else {
      create.mutate({
        body: { data: { type: 'ai_gateway_provider', attributes: { credential: body } } },
        path: { provider_id: provider.provider_id }
      })
    }
  }
  const pending = create.isPending || update.isPending
  const error = validationError ?? create.error ?? update.error ?? decrypt.error
  const incomplete = !label.trim() || Boolean(missingRequiredSecretSetting(entry, settings, values, baselineValues))
  const dirty =
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    settings.some(setting => (values[setting.key] ?? '') !== (baselineValues[setting.key] ?? ''))
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending, onOpenChange })

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!pending}>
        <DialogHeader>
          <DialogTitle>
            {entry ? t('console.providers.edit_credential') : t('console.providers.add_credential')}
          </DialogTitle>
          <DialogDescription>
            {metadataOnly
              ? t('console.providers.chatgpt_credential_editor_description')
              : t('console.providers.credential_editor_description')}
          </DialogDescription>
        </DialogHeader>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            submit()
          }}>
          <div className="grid max-h-[65vh] gap-4 overflow-y-auto py-1">
            {error ? (
              <p className="text-sm text-destructive-foreground" aria-live="assertive">
                {requestErrorMessage(error)}
              </p>
            ) : null}
            <LabeledField label={t('console.providers.credential_label')} required>
              <Input value={label} onChange={event => setLabel(event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.providers.priority')}>
              <Input type="number" step={1} value={priority} onChange={event => setPriority(event.target.value)} />
            </LabeledField>
            {settings.map(setting => {
              const present = entryHasSecretField(entry, setting.key)
              return (
                <ProviderSettingField
                  key={setting.key}
                  setting={setting}
                  keepStored={Boolean(entry)}
                  secretPresent={present}
                  decrypt={
                    present
                      ? {
                          onReveal: () => revealField(setting.key),
                          revealed: Boolean(revealedKeys[setting.key]),
                          revealing: decrypt.isRevealing(setting.key)
                        }
                      : undefined
                  }
                  value={values[setting.key] ?? ''}
                  onChange={value => {
                    decrypt.cancelTarget(setting.key)
                    setValues(current => ({ ...current, [setting.key]: value }))
                    setValidationError(undefined)
                  }}
                />
              )
            })}
            {readOnlySecrets.map(setting => (
              <ProviderSettingField
                key={setting.key}
                setting={setting}
                readOnly
                secretPresent
                decrypt={{
                  onReveal: () => revealField(setting.key),
                  revealed: Boolean(revealedKeys[setting.key]),
                  revealing: decrypt.isRevealing(setting.key)
                }}
                value={values[setting.key] ?? ''}
                onChange={() => {}}
              />
            ))}
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

function CredentialFact({ label, value }: { label: string; value: string | null | undefined }) {
  if (!value) return null

  return (
    <div className="grid gap-1 sm:grid-cols-[minmax(8rem,0.4fr)_1fr] sm:gap-3">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="break-all font-mono tabular-nums">{value}</dd>
    </div>
  )
}

function CredentialSecretFact({
  actionLabel,
  label,
  onToggle,
  revealedValue,
  revealing
}: {
  actionLabel: string
  label: string
  onToggle: () => void
  revealedValue: string | undefined
  revealing: boolean
}) {
  return (
    <div className="grid gap-1 sm:grid-cols-[minmax(8rem,0.4fr)_1fr] sm:gap-3">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="flex min-w-0 items-center gap-1.5 font-mono tabular-nums">
        <span className={revealedValue === undefined ? 'text-muted-foreground' : 'break-all'}>
          {revealedValue ?? '••••••'}
        </span>
        <button
          aria-label={actionLabel}
          className="grid size-8 shrink-0 place-items-center text-muted-foreground hover:bg-muted hover:text-foreground disabled:cursor-wait disabled:opacity-60"
          disabled={revealing}
          title={actionLabel}
          type="button"
          onClick={onToggle}>
          {revealing ? (
            <Spinner className="size-4" />
          ) : revealedValue === undefined ? (
            <EyeRegular className="size-4" />
          ) : (
            <EyeOffRegular className="size-4" />
          )}
        </button>
      </dd>
    </div>
  )
}

function CredentialDiagnostics({ label, value }: { label: string; value: string | undefined }) {
  if (!value) return null

  return (
    <details>
      <summary className="cursor-pointer text-sm font-medium">{label}</summary>
      <pre className="mt-2 max-h-56 overflow-auto whitespace-pre-wrap break-all border border-border bg-muted p-3 text-xs">
        {value}
      </pre>
    </details>
  )
}

function credentialStatusTone(
  status: AIGatewayCredentialPoolEntry['status']
): 'danger' | 'neutral' | 'positive' | 'warning' {
  switch (status) {
    case 'ok':
      return 'positive'
    case 'exhausted':
      return 'warning'
    case 'dead':
      return 'danger'
    case 'disabled':
      return 'neutral'
  }
}

function formatCredentialUsage(t: TFunction, value: Record<string, unknown>): string | undefined {
  const buckets = [
    [t('console.providers.usage_model'), recordValue(value.model)],
    [t('console.providers.usage_image_generation'), recordValue(value.image_gen)]
  ] as const

  const parts = buckets.flatMap(([name, usage]) => {
    if (!usage) return []
    const total = numberValue(usage.total_tokens)
    const input = numberValue(usage.input_tokens) ?? numberValue(usage.prompt_tokens)
    const output = numberValue(usage.output_tokens) ?? numberValue(usage.completion_tokens)
    if (total === undefined && input === undefined && output === undefined) return []

    return [
      t('console.providers.usage_bucket', {
        name,
        total: total ?? (input ?? 0) + (output ?? 0),
        input: input ?? 0,
        output: output ?? 0
      })
    ]
  })

  return parts.length > 0 ? parts.join(' · ') : undefined
}

function formatRateLimits(value: Record<string, unknown>): string | undefined {
  const parts = Object.entries(value)
    .filter((entry): entry is [string, string] => typeof entry[1] === 'string')
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([name, limit]) => `${name.replace(/^x-codex-/, '')}: ${limit}`)

  return parts.length > 0 ? parts.join('\n') : undefined
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

export function credentialStrategyLabel(
  t: ReturnType<typeof useTranslation>['t'],
  strategy: CredentialStrategy
): string {
  switch (strategy) {
    case 'fill_first':
      return t('console.providers.strategy_fill_first')
    case 'round_robin':
      return t('console.providers.strategy_round_robin')
    case 'least_used':
      return t('console.providers.strategy_least_used')
    case 'random':
      return t('console.providers.strategy_random')
  }
}

function credentialSourceLabel(t: TFunction, source: string): string {
  switch (source) {
    case 'manual':
    case 'provider_default':
    case 'device_oauth':
    case 'browser_oauth':
    case 'enterprise_access_token':
      return t(`console.providers.source_${source}`)
    default:
      return humanizeKey(source)
  }
}
