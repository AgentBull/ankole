import { Field, FieldLabel, Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useId, type ComponentProps } from 'react'
import { useTranslation } from 'react-i18next'
import { ConfigFields, defaultConfig } from './config-fields'
import type { PodConnectorAuthConfigsListResponse, PodConnectorsCatalogResponse } from '../pod/api/generated/types.gen'

export function ConnectorConfigFields({
  pluginId,
  onConnectionChange,
  catalog,
  connections,
  ...props
}: ComponentProps<typeof ConfigFields> & {
  pluginId: string
  onConnectionChange(config: ComponentProps<typeof ConfigFields>['config']): void
  catalog: PodConnectorsCatalogResponse['connectors']
  connections: PodConnectorAuthConfigsListResponse['connections']
}) {
  const id = useId()
  const { t } = useTranslation()
  const platform = pluginId.replace(/-adapter$/, '')
  const declaration = catalog?.find(item => item.plugin_id === platform)
  const selected = typeof props.config.authConfigId === 'string' ? props.config.authConfigId : null
  const saved = connections.filter(
    item =>
      item.id != null &&
      item.mode !== 'cloud' &&
      item.plugin_id === platform &&
      (item.status === 'active' || item.id === selected)
  )
  const connectionKeys = new Set(
    [...(declaration?.credential_fields ?? []), ...(declaration?.public_fields ?? [])].map(field => field.key)
  )
  const connection = saved.find(item => item.id === selected)
  const configuredKeys = new Set([
    ...(connection?.configured_credential_fields ?? []),
    ...Object.entries(connection?.public_metadata ?? {})
      .filter(([, value]) => value !== null && value !== '')
      .map(([key]) => key)
  ])
  const fields = selected
    ? props.fields.filter(field => !connectionKeys.has(field.path) || !configuredKeys.has(field.path))
    : props.fields

  return (
    <>
      {saved.length > 0 ? (
        <Field>
          <FieldLabel htmlFor={id}>{t('pod.connectors.connection')}</FieldLabel>
          <Select
            value={selected ?? 'new'}
            onValueChange={value =>
              onConnectionChange({
                ...(value === 'new' ? defaultConfig(props.fields.filter(field => connectionKeys.has(field.path))) : {}),
                ...Object.fromEntries(Object.entries(props.config).filter(([key]) => !connectionKeys.has(key))),
                authConfigId: value === 'new' ? null : String(value)
              })
            }>
            <SelectTrigger id={id} className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="new">{t('pod.connectors.enter_credentials')}</SelectItem>
              {saved.map(connection => (
                <SelectItem key={connection.id} value={connection.id!} disabled={connection.status !== 'active'}>
                  {connection.display_name} · {connection.slug}
                  {connection.status !== 'active' ? ` · ${t(`pod.connectors.status.${connection.status}`)}` : ''}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
      ) : null}
      <ConfigFields {...props} fields={fields} />
    </>
  )
}
