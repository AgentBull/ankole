import { Badge, Button, TableCell, TableRow, buttonVariants, cn, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
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
import { JSONField, LabeledField, ResourceEditorPage, ResourceListPage } from '../console-shell'
import { SettingEditorModel } from '../state/setting-editor-model'

export function SettingsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const items = list.data?.app_configurations ?? []

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
      error={list.error}>
      {items.map(item => (
        <TableRow
          key={`${item.kind}:${item.key}`}
          className={item.editable ? 'cursor-pointer' : undefined}
          onClick={() => item.editable && navigate(encodeURIComponent(item.key))}>
          <TableCell className="max-w-[360px] font-mono text-xs break-all whitespace-normal">{item.key}</TableCell>
          <TableCell>
            <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
          </TableCell>
          <TableCell>{item.source}</TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1.5">
              {item.encrypted ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
              {item.overridden ? <Badge>{t('console.status.global')}</Badge> : null}
            </div>
          </TableCell>
          <TableCell className="text-right">
            {item.editable ? (
              <Link
                to={encodeURIComponent(item.key)}
                onClick={event => event.stopPropagation()}
                className={cn(buttonVariants({ size: 'xs', variant: 'ghost' }))}>
                {t('common.edit')}
              </Link>
            ) : (
              <span className="pr-2 text-xs text-muted-foreground">{t('console.settings.read_only')}</span>
            )}
          </TableCell>
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
      navigate('..')
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
      backTo=".."
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
        <JSONField
          label={t('console.settings.value')}
          value={model.text.value}
          minRows={10}
          onChange={value => (model.text.value = value)}
        />
      )}
    </ResourceEditorPage>
  )
}
