import { Badge, Button, Input, Switch, TableCell, TableRow, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAppConfigurationControllerDecryptMutation,
  ankoleWebAppConfigurationControllerDeleteMutation,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAppConfigurationControllerShowOptions,
  ankoleWebAppConfigurationControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { formatJSON, parseJSON } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, EncryptedValueInput, isEncryptedValueMask } from '../encrypted-value-input'
import {
  JSONField,
  LabeledField,
  ResourceEditorPage,
  ResourceListPage,
  ResourceSearch,
  RowActions
} from '../console-shell'
import { SettingEditorModel } from '../state/setting-editor-model'
import { matchesResourceSearch } from '../state/resource-search'
import { settingStringDraft, settingValueKind } from '../state/setting-value-editor'

export function SettingsListPage() {
  const { t } = useTranslation()
  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const items = (list.data?.app_configurations ?? []).filter(item =>
    matchesResourceSearch(
      deferredQuery,
      item.key,
      item.description,
      item.kind,
      item.source,
      item.encrypted ? 'encrypted' : '',
      item.overridden ? 'overridden' : ''
    )
  )

  return (
    <ResourceListPage
      title={t('console.settings.title')}
      description={t('console.settings.description')}
      columns={[
        t('console.settings.key'),
        t('console.settings.kind'),
        t('console.settings.source'),
        t('console.settings.state')
      ]}
      isLoading={list.isLoading}
      isEmpty={items.length === 0}
      emptyTitle={t('console.settings.empty_title')}
      emptyDescription={t('console.no_settings')}
      error={list.error}
      isFiltered={Boolean(query.trim())}
      toolbar={
        <ResourceSearch
          label={t('console.settings.search')}
          placeholder={t('console.settings.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {items.map(item => (
        <TableRow key={`${item.kind}:${item.key}`}>
          <TableCell className="max-w-[360px] font-mono text-xs break-all whitespace-normal">
            {item.editable ? (
              <Link className="text-foreground hover:text-primary hover:underline" to={encodeURIComponent(item.key)}>
                {item.key}
              </Link>
            ) : (
              item.key
            )}
          </TableCell>
          <TableCell>
            <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
          </TableCell>
          <TableCell>{t(`console.settings.source_${item.source}`)}</TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1.5">
              {item.encrypted ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
              {item.overridden ? <Badge variant="success">{t('console.status.global')}</Badge> : null}
            </div>
          </TableCell>
          {item.editable ? (
            <RowActions editTo={encodeURIComponent(item.key)} editLabel={t('common.edit')} />
          ) : (
            <TableCell className="text-right">
              <span className="pr-2 text-xs text-muted-foreground">{t('console.settings.read_only')}</span>
            </TableCell>
          )}
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function SettingEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(SettingEditorModel)
  const params = useParams()
  const key = params.key ? decodeURIComponent(params.key) : ''

  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const summary = list.data?.app_configurations.find(item => item.key === key)
  const detail = useQuery({
    ...ankoleWebAppConfigurationControllerShowOptions({ path: { key } }),
    enabled: Boolean(summary?.editable && key)
  })
  const item = detail.data?.app_configuration ?? summary

  const refresh = () => void queryClient.invalidateQueries()
  const update = useMutation({
    ...ankoleWebAppConfigurationControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.settings.saved', { key: response.app_configuration.key }))
      refresh()
      navigate('/settings')
    }
  })
  const reset = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: () => {
      toast.success(t('console.settings.reset_done', { key }))
      model.resetSource()
      decrypt.reset()
      refresh()
    },
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
  })
  const decrypt = useMutation({
    ...ankoleWebAppConfigurationControllerDecryptMutation(),
    gcTime: 0,
    onSuccess: response => {
      model.text.value = JSON.stringify(response.decrypted_value.value) ?? ''
    },
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
  })

  useEffect(() => {
    decrypt.reset()
    if (!item || detail.isLoading) return
    model.initialize(
      `setting:${item.key}`,
      item.encrypted ? (item.present ? ENCRYPTED_VALUE_MASK : '') : formatJSON(item.value ?? null)
    )
  }, [detail.isLoading, item, model])

  const submit = () => {
    model.clearValidation()
    if (!item) return
    if (item.encrypted && isEncryptedValueMask(model.text.value)) {
      update.mutate({ body: {}, path: { key: item.key } })
      return
    }
    const parsed = parseJSON(model.text.value, 'value')
    if (!parsed.ok) {
      model.validationError.value = parsed.error
      return
    }
    update.mutate({ body: { value: parsed.value }, path: { key: item.key } })
  }

  return (
    <ResourceEditorPage
      title={key}
      description={item?.description ?? t('console.settings.editor_description')}
      backTo="/settings"
      error={model.validationError.value ?? update.error ?? decrypt.error}
      submitting={update.isPending}
      onSubmit={submit}
      secondary={
        item?.editable ? (
          <Button
            disabled={reset.isPending}
            size="sm"
            type="button"
            variant="outline"
            onClick={() => reset.mutate({ path: { key: item.key } })}>
            {t('console.settings.reset')}
          </Button>
        ) : null
      }>
      <div className="flex flex-wrap items-center gap-2">
        {item ? <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge> : null}
        {item ? <Badge variant="outline">{item.source}</Badge> : null}
        {item?.encrypted ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
      </div>

      {item?.encrypted ? (
        <LabeledField
          htmlFor="app-configuration-value"
          label={t('console.settings.value')}
          description={t('console.settings.encrypted_value_hint')}
          required>
          <EncryptedValueInput
            id="app-configuration-value"
            className="font-mono"
            revealLabel={t('console.settings.reveal')}
            revealed={decrypt.data?.decrypted_value.key === item.key}
            revealing={decrypt.isPending}
            value={model.text.value}
            onChange={event => (model.text.value = event.target.value)}
            onReveal={() => decrypt.mutate({ path: { key: item.key } })}
          />
        </LabeledField>
      ) : (
        <SettingValueField
          kind={settingValueKind(item?.value)}
          label={t('console.settings.value')}
          value={model.text.value}
          onChange={value => (model.text.value = value)}
        />
      )}
    </ResourceEditorPage>
  )
}

function SettingValueField({
  kind,
  label,
  onChange,
  value
}: {
  kind: ReturnType<typeof settingValueKind>
  label: string
  onChange: (value: string) => void
  value: string
}) {
  if (kind === 'boolean') {
    return (
      <LabeledField label={label}>
        <div className="flex min-h-12 items-center justify-between border border-border bg-muted/30 px-4 py-3">
          <span className="text-sm text-foreground">{value === 'true' ? 'true' : 'false'}</span>
          <Switch checked={value === 'true'} onCheckedChange={checked => onChange(checked ? 'true' : 'false')} />
        </div>
      </LabeledField>
    )
  }

  if (kind === 'number') {
    return (
      <LabeledField label={label} required>
        <Input type="number" step="any" value={value} onChange={event => onChange(event.target.value)} />
      </LabeledField>
    )
  }

  if (kind === 'string') {
    return (
      <LabeledField label={label} required>
        <Input value={settingStringDraft(value)} onChange={event => onChange(JSON.stringify(event.target.value))} />
      </LabeledField>
    )
  }

  return <JSONField label={label} value={value} minRows={8} onChange={onChange} />
}
