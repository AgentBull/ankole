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
  toast
} from '@ankole/uikit'
import { RiAddLine, RiRefreshLine } from '@remixicon/react'
import { useMutation } from '@tanstack/react-query'
import type { TFunction } from 'i18next'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../../common/request-errors'
import {
  addAiGatewayCredentialMutation as addCredentialMutation,
  deleteAiGatewayCredentialMutation as deleteCredentialMutation,
  putAiGatewayCredentialMutation as putCredentialMutation,
  putAiGatewayCredentialStrategyMutation as putCredentialStrategyMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import type { AIGatewayProviderKindItem } from '../state/provider-settings'
import {
  ConfirmDeleteButton,
  DiscardConfirmDialog,
  LabeledField,
  SaveButton,
  StatusIndicator,
  useDialogDiscardGuard
} from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import {
  aiGatewayProvider,
  buildSettingOptions,
  credentialSettings,
  humanizeKey,
  settingValidationMessage
} from '../state/provider-settings'
import { ProviderSettingField, providerSettingLabel } from './provider-setting-field'

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
  const isChatGPT = provider.provider_kind === 'chatgpt_subscription'

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
    onSuccess: () => {
      toast.success(t('console.providers.credential_saved'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeCredential = useMutation({
    ...deleteCredentialMutation(),
    onSuccess: () => {
      toast.success(t('console.providers.credential_deleted'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

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
          <h3 className="text-lg font-semibold">{t('console.providers.pool_title')}</h3>
          <p className="max-w-2xl text-sm text-muted-foreground">{t('console.providers.pool_description')}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {isChatGPT ? (
            <>
              <Button size="sm" type="button" onClick={() => setChatGPTLoginEntry(null)}>
                <RiAddLine data-icon="inline-start" />
                {t('console.providers.add_chatgpt_account')}
              </Button>
              <Button size="sm" type="button" variant="outline" onClick={() => setEnterpriseEntry(null)}>
                <RiAddLine data-icon="inline-start" />
                {t('console.providers.add_enterprise_token')}
              </Button>
            </>
          ) : (
            <Button size="sm" type="button" onClick={() => setCredentialEditor(null)}>
              <RiAddLine data-icon="inline-start" />
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
                      <RiRefreshLine data-icon="inline-start" />
                      {t('console.providers.reauthenticate')}
                    </Button>
                  ) : null}
                  <Button size="xs" type="button" variant="outline" onClick={() => setCredentialEditor(entry)}>
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
        onOpenChange={open => !open && setCredentialEditor(undefined)}
      />
      <ChatGPTLoginDialog
        entry={chatGPTLoginEntry}
        provider={provider}
        open={chatGPTLoginEntry !== undefined}
        onOpenChange={open => !open && setChatGPTLoginEntry(undefined)}
      />
      <EnterpriseCredentialDialog
        entry={enterpriseEntry}
        provider={provider}
        open={enterpriseEntry !== undefined}
        onOpenChange={open => !open && setEnterpriseEntry(undefined)}
      />
    </section>
  )
}

function CredentialEditorDialog({
  entry,
  onOpenChange,
  open,
  provider,
  providerKind
}: {
  entry: AIGatewayCredentialPoolEntry | null | undefined
  onOpenChange: (open: boolean) => void
  open: boolean
  provider: AIGatewayProviderItem
  providerKind: AIGatewayProviderKindItem
}) {
  const { t } = useTranslation()
  // ChatGPT pool entries hold OAuth tokens owned by the login flow, so the
  // editor exposes only label and priority; the control plane keeps the
  // stored values of every omitted field.
  const metadataOnly = provider.provider_kind === 'chatgpt_subscription'
  const settings = useMemo(() => (metadataOnly ? [] : credentialSettings(providerKind)), [metadataOnly, providerKind])
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [values, setValues] = useState<Record<string, string>>({})
  const [validationError, setValidationError] = useState<string>()

  const finish = () => {
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

  useEffect(() => {
    if (!open) return
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    // Reset only when a new editing session opens. Rendering falls back to ''
    // per key, so the cleared map needs no entries — and no `settings`
    // dependency, whose query-driven identity must not wipe in-progress input.
    setValues({})
    setValidationError(undefined)
    create.reset()
    update.reset()
  }, [entry, open])

  const submit = () => {
    setValidationError(undefined)
    if (!label.trim()) {
      setValidationError(t('console.providers.credential_label_required'))
      return
    }
    if (!entry) {
      const missing = settings.find(setting => {
        const value = values[setting.key]?.trim()
        return setting.required && !value
      })
      if (missing) {
        setValidationError(settingValidationMessage(providerSettingLabel(t, missing.key), 'required'))
        return
      }
    }

    const built = buildSettingOptions(settings, values, settingValidationMessage, key => providerSettingLabel(t, key))
    if (!built.ok) {
      setValidationError(built.error)
      return
    }
    const body = {
      label: label.trim(),
      priority: Number.parseInt(priority, 10) || 0,
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
  const error = validationError ?? create.error ?? update.error
  const incomplete =
    !label.trim() ||
    (!entry &&
      settings.some(setting => {
        const value = values[setting.key]?.trim()
        return setting.required && !value
      }))
  const dirty =
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    Object.values(values).some(value => value.trim() !== '')
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
            {settings.map(setting => (
              <ProviderSettingField
                key={setting.key}
                setting={setting}
                keepStored={Boolean(entry)}
                secretPresent={Boolean(entry?.credential_present)}
                value={values[setting.key] ?? ''}
                onChange={value => setValues(current => ({ ...current, [setting.key]: value }))}
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
