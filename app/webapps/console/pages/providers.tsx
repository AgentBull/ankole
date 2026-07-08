import {
  Badge,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiArrowDownSLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAiGatewayProviderControllerDeleteProviderMutation,
  ankoleWebAiGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions,
  ankoleWebAiGatewayProviderControllerPutProviderMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { AiGatewayProviderItem, AiGatewayProviderKindItem } from '../api/generated/types.gen'
import i18n from '../../common/i18n'
import { requestErrorMessage } from '../../common/request-errors'
import {
  JsonField,
  LabeledField,
  ResourceEditorPage,
  ResourceListPage,
  RowActions,
  SecretInput
} from '../console-shell'
import {
  buildConnectionOptions,
  connectionSettings,
  encryptedOptionState,
  humanizeKey,
  initialSettingValue,
  type ProviderSetting
} from './provider-settings'

export function ProvidersListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const providers = useQuery(ankoleWebAiGatewayProviderControllerIndexOptions())
  const rows = providers.data?.data ?? []
  const deleteProvider = useMutation({
    ...ankoleWebAiGatewayProviderControllerDeleteProviderMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.providers.deleted', { id: variables.path.provider_id }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.providers.title')}
      description={t('console.providers.description')}
      createTo="new"
      createLabel={t('console.providers.new')}
      columns={[
        t('console.providers.provider'),
        t('console.providers.kind'),
        t('console.providers.credentials'),
        t('console.providers.state')
      ]}
      isLoading={providers.isLoading}
      isEmpty={rows.length === 0}
      emptyTitle={t('console.providers.empty_title')}
      emptyDescription={t('console.providers.empty_description')}
      error={providers.error}>
      {rows.map(provider => (
        <TableRow
          key={provider.provider_id}
          className="cursor-pointer"
          onClick={() => navigate(encodeURIComponent(provider.provider_id))}>
          <TableCell className="font-mono text-xs">{provider.provider_id}</TableCell>
          <TableCell>{provider.provider_kind}</TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1.5">
              {Object.entries(provider.encrypted_options).map(([key, option]) => (
                <Badge key={key} variant={option.present ? 'default' : 'outline'}>
                  {key}
                </Badge>
              ))}
            </div>
          </TableCell>
          <TableCell>
            <Badge variant={provider.disabled_at ? 'secondary' : 'default'}>
              {provider.disabled_at ? t('console.status.disabled') : t('console.status.enabled')}
            </Badge>
          </TableCell>
          <RowActions
            editTo={encodeURIComponent(provider.provider_id)}
            editLabel={t('common.edit')}
            deletePending={deleteProvider.isPending}
            deleteConfirm={{
              title: t('console.providers.delete_title'),
              description: t('console.providers.delete_description', { id: provider.provider_id }),
              confirmLabel: t('common.disable')
            }}
            onDelete={() => deleteProvider.mutate({ path: { provider_id: provider.provider_id } })}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

type ProviderForm = {
  providerId: string
  providerKind: string
  baseUrl: string
  options: Record<string, string>
}

export function ProviderEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const providerId = params.providerId ? decodeURIComponent(params.providerId) : undefined
  const mode = providerId ? 'edit' : 'new'

  const providers = useQuery(ankoleWebAiGatewayProviderControllerIndexOptions())
  const providerKinds = useQuery(ankoleWebAiGatewayProviderControllerProviderKindsOptions())
  const kinds = providerKinds.data?.data ?? []
  const selected = providers.data?.data.find(provider => provider.provider_id === providerId)

  const [form, setForm] = useState<ProviderForm>({ providerId: '', providerKind: '', baseUrl: '', options: {} })
  const [error, setError] = useState<string>()

  const activeKind = kinds.find(kind => kind.provider_kind === form.providerKind)
  const settings = useMemo(() => connectionSettings(activeKind), [activeKind])

  // Initialize the form once per edited target (or once kinds load for a new
  // provider). Manual edits — including switching kind — mutate `form` directly
  // afterwards, so this effect must not depend on the live kind selection.
  const ready = kinds.length > 0 && (mode === 'new' || Boolean(selected))
  useEffect(() => {
    if (!ready) return
    if (mode === 'edit' && selected) {
      const kind = kinds.find(item => item.provider_kind === selected.provider_kind)
      setForm({
        providerId: selected.provider_id,
        providerKind: selected.provider_kind,
        baseUrl: selected.base_url ?? '',
        options: initialOptions(connectionSettings(kind), selected)
      })
    } else if (mode === 'new') {
      const kind = kinds[0]
      setForm({
        providerId: '',
        providerKind: kind?.provider_kind ?? '',
        baseUrl: kind?.default_base_url ?? '',
        options: initialOptions(connectionSettings(kind), undefined)
      })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, mode, providerId])

  const saveProvider = useMutation({
    ...ankoleWebAiGatewayProviderControllerPutProviderMutation(),
    onSuccess: response => {
      toast.success(t('console.providers.saved', { id: response.data.provider_id }))
      void queryClient.invalidateQueries()
      navigate('..')
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })

  const changeKind = (providerKind: string) => {
    const kind = kinds.find(item => item.provider_kind === providerKind)
    setForm({
      providerId: form.providerId,
      providerKind,
      baseUrl: kind?.default_base_url ?? '',
      options: initialOptions(connectionSettings(kind), undefined)
    })
  }

  const submit = () => {
    setError(undefined)
    const trimmedId = form.providerId.trim()
    if (!trimmedId) {
      setError(t('console.providers.provider_id_required'))
      return
    }

    const built = buildConnectionOptions(settings, form.options, field =>
      i18n.t('common.must_be_json_object', { field })
    )
    if (!built.ok) {
      setError(built.error)
      return
    }

    saveProvider.mutate({
      body: {
        provider_id: trimmedId,
        provider_kind: form.providerKind,
        base_url: form.baseUrl.trim() ? form.baseUrl.trim() : null,
        connection_options: built.value
      },
      path: { provider_id: trimmedId }
    })
  }

  const mapSettings = settings.filter(setting => setting.isMap)
  const plainSettings = settings.filter(setting => !setting.isMap)

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.providers.new') : (providerId ?? '')}
      description={t('console.providers.editor_description')}
      backTo=".."
      error={error ?? saveProvider.error}
      submitting={saveProvider.isPending}
      onSubmit={submit}>
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.providers.provider_id')} description={t('console.providers.provider_id_hint')}>
          <Input
            disabled={mode === 'edit'}
            placeholder="openai"
            value={form.providerId}
            onChange={event => setForm(current => ({ ...current, providerId: event.target.value }))}
          />
        </LabeledField>
        <LabeledField label={t('console.providers.kind')}>
          <Select
            disabled={mode === 'edit'}
            value={form.providerKind}
            onValueChange={value => changeKind(String(value))}>
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {kinds.map(kind => (
                <SelectItem key={kind.provider_kind} value={kind.provider_kind}>
                  {providerKindLabel(kind)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </LabeledField>
      </div>

      <LabeledField label={t('console.providers.base_url')} description={t('console.providers.base_url_hint')}>
        <Input
          placeholder={activeKind?.default_base_url ?? 'https://api.example.com/v1'}
          value={form.baseUrl}
          onChange={event => setForm(current => ({ ...current, baseUrl: event.target.value }))}
        />
      </LabeledField>

      {plainSettings.map(setting => (
        <SettingField
          key={setting.key}
          setting={setting}
          provider={selected}
          value={form.options[setting.key] ?? ''}
          onChange={value =>
            setForm(current => ({ ...current, options: { ...current.options, [setting.key]: value } }))
          }
        />
      ))}

      {mapSettings.length > 0 ? (
        <Collapsible className="grid gap-4" defaultOpen={false}>
          <CollapsibleTrigger className="flex w-full items-center justify-between gap-3 border border-border bg-muted/40 px-4 py-3 text-left text-sm font-medium">
            <span>{t('common.advanced_settings')}</span>
            <span className="flex items-center gap-2 text-xs text-muted-foreground">
              {mapSettings.length}
              <RiArrowDownSLine className="size-4" aria-hidden />
            </span>
          </CollapsibleTrigger>
          <CollapsibleContent className="grid gap-5">
            {mapSettings.map(setting => (
              <SettingField
                key={setting.key}
                setting={setting}
                provider={selected}
                value={form.options[setting.key] ?? ''}
                onChange={value =>
                  setForm(current => ({ ...current, options: { ...current.options, [setting.key]: value } }))
                }
              />
            ))}
          </CollapsibleContent>
        </Collapsible>
      ) : null}

      {mode === 'edit' ? (
        <p className="text-xs text-muted-foreground">
          {t('console.providers.model_profiles_hint')}{' '}
          <Link to="/agents" className="text-primary underline underline-offset-4">
            {t('console.nav.agents')}
          </Link>
        </p>
      ) : null}
    </ResourceEditorPage>
  )
}

function SettingField({
  onChange,
  provider,
  setting,
  value
}: {
  onChange: (value: string) => void
  provider: AiGatewayProviderItem | undefined
  setting: ProviderSetting
  value: string
}) {
  const { t } = useTranslation()
  const label = humanizeKey(setting.key)

  if (setting.encrypted) {
    const state = encryptedOptionState(provider, setting.key)
    const description = state?.present
      ? t('console.providers.secret_keep', { masked: state.masked ?? '••••' })
      : t('console.providers.secret_hint')
    return (
      <LabeledField label={label} description={description} required={setting.required && !state?.present}>
        <SecretInput placeholder="sk-..." value={value} onChange={event => onChange(event.target.value)} />
      </LabeledField>
    )
  }

  if (setting.isMap) {
    return (
      <JsonField
        label={label}
        description={t('console.providers.map_hint')}
        minRows={4}
        value={value}
        onChange={onChange}
      />
    )
  }

  return (
    <LabeledField label={label} required={setting.required}>
      <Input
        placeholder={setting.default != null ? String(setting.default) : undefined}
        value={value}
        onChange={event => onChange(event.target.value)}
      />
    </LabeledField>
  )
}

function initialOptions(
  settings: ProviderSetting[],
  provider: AiGatewayProviderItem | undefined
): Record<string, string> {
  return Object.fromEntries(settings.map(setting => [setting.key, initialSettingValue(setting, provider)]))
}

function providerKindLabel(kind: AiGatewayProviderKindItem): string {
  const label = kind.label.en ?? kind.label['en-US'] ?? kind.label.default ?? kind.provider_kind
  return `${label} (${kind.provider_kind})`
}
