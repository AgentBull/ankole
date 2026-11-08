import {
  Button,
  Checkbox,
  Dialog,
  DialogContent,
  DialogTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { ConfigField, localizedText, type ConfigFieldDefinition } from '../common/config-fields'
import { ContentError } from './content-primitives'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import * as api from './api/generated/sdk.gen'
import { ConnectionAccessFields } from './connector-connection-access'
import {
  ConnectionEditorModel,
  connectorCredentialFields,
  DATABASE_CONNECTORS,
  type ConnectorConnection,
  type ConnectorDefinition
} from './state/connectors'

export function ConnectionEditorDialog({
  connection,
  connectors,
  callbackURL,
  onClose,
  onRefresh
}: {
  connection: ConnectorConnection | null
  connectors: ConnectorDefinition[]
  callbackURL?: string
  onClose(): void
  onRefresh(): Promise<unknown>
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const model = useModel(() => new ConnectionEditorModel(connection))
  const save = useMutation({
    mutationFn: async () => {
      const secret = Object.fromEntries(Object.entries(model.secret.value).filter(([, value]) => value !== ''))
      const tokenCredentials = ['api_token', 'personal_token'].includes(model.scheme.value)
      const definition = connectors.find(item => item.plugin_id === model.plugin.value)
      const defaults = Object.fromEntries(
        (definition?.public_fields ?? [])
          .filter(
            field =>
              field.default !== undefined &&
              field.default !== null &&
              (!Array.isArray(field.schemes) || field.schemes.includes(model.scheme.value))
          )
          .map(field => [String(field.key), field.default])
      )
      const data = {
        slug: model.slug.value,
        display_name: model.name.value,
        is_default: model.isDefault.value,
        public_metadata: { ...defaults, ...model.metadata.value },
        secret: tokenCredentials ? {} : secret,
        ...(DATABASE_CONNECTORS.includes(model.plugin.value) ? { access: model.access.value } : {})
      }
      const result = model.editing.value?.id
        ? await api.podConnectorAuthConfigsUpdate({ path: { id: model.editing.value.id }, body: { data } })
        : await api.podConnectorAuthConfigsCreate({
            body: { data: { ...data, plugin_id: model.plugin.value, auth_scheme: model.scheme.value } }
          })
      // Keep a saved connection as the retry target if credential verification fails.
      model.editing.value = result.connection
      if (tokenCredentials && (secret.access_token || secret.api_token)) {
        await api.podConnectorAccountsConnectTeam({
          body: { data: { connection: result.connection.slug, credentials: secret } }
        })
      }
      return result
    },
    onError: onRefresh,
    onSuccess: async () => {
      onClose()
      await onRefresh()
    }
  })
  const connector = connectors.find(item => item.plugin_id === model.plugin.value)
  const fields = (items: Record<string, unknown>[] | null | undefined, secret: boolean) =>
    (secret
      ? connectorCredentialFields(items ?? [], model.scheme.value, Boolean(model.editing.value))
      : (items ?? []).filter(field => !Array.isArray(field.schemes) || field.schemes.includes(model.scheme.value))
    ).map(field => {
      const path = String(field.key)
      const values = secret ? model.secret : model.metadata
      const definition: ConfigFieldDefinition = {
        path,
        // Plugins declare either one plain label or a map of localized labels.
        label:
          typeof field.label === 'object' && field.label
            ? (field.label as Record<string, string>)
            : { default: String(field.label || path) },
        type: String(field.type ?? 'string'),
        encrypted: field.secret === true,
        required: field.required === true,
        options: Array.isArray(field.options)
          ? field.options.map(option =>
              typeof option === 'string'
                ? { value: option }
                : {
                    value: String(option.value),
                    label: typeof option.label === 'string' ? { default: option.label } : option.label
                  }
            )
          : []
      }
      return (
        <ConfigField
          key={`${secret}:${path}`}
          field={definition}
          locale={i18n.language}
          value={
            values.value[path] ??
            (secret && field.secret !== true ? model.metadata.value[path] : undefined) ??
            (secret ? '' : field.default)
          }
          required={definition.required === true && !(secret && model.editing.value)}
          placeholder={
            secret && field.secret === true && model.editing.value ? t('pod.connectors.keep_secret') : undefined
          }
          onChange={value => {
            values.value = { ...values.value, [path]: value }
          }}
        />
      )
    })
  return (
    <Dialog
      open
      onOpenChange={open => {
        if (!open) onClose()
      }}>
      <DialogContent closeLabel={t('common.close')} className="max-h-[85dvh] overflow-y-auto">
        <DialogTitle>{t(model.editing.value ? 'pod.connectors.edit' : 'pod.connectors.add')}</DialogTitle>
        <ContentError error={save.error} />
        <form
          method="post"
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            save.mutate()
          }}>
          {!model.editing.value && (
            <>
              <Label>{t('pod.connectors.platform')}</Label>
              <Select
                value={model.plugin.value}
                onValueChange={value => {
                  if (!value) return
                  model.plugin.value = value
                  model.scheme.value = connectors.find(item => item.plugin_id === value)?.auth_schemes?.[0] ?? ''
                  model.secret.value = {}
                  model.metadata.value = {}
                }}>
                <SelectTrigger aria-label={t('pod.connectors.platform')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {connectors.map(item => (
                    <SelectItem key={item.plugin_id} value={item.plugin_id!}>
                      {localizedText(item.display_name, i18n.language) ?? item.plugin_id}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {(connector?.auth_schemes?.length ?? 0) > 1 && (
                <>
                  <Label>{t('pod.connectors.auth_scheme')}</Label>
                  <Select
                    value={model.scheme.value}
                    onValueChange={value => {
                      if (!value) return
                      model.scheme.value = value
                      model.secret.value = {}
                      model.metadata.value = {}
                    }}>
                    <SelectTrigger aria-label={t('pod.connectors.auth_scheme')}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {connector!.auth_schemes!.map(value => (
                        <SelectItem key={value} value={value}>
                          {humanizeTechnicalLabel(value)}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </>
              )}
            </>
          )}
          {['lark', 'github', 'linear'].includes(model.plugin.value) && (
            <details className="rounded-lg border p-3 text-sm">
              <summary className="cursor-pointer font-medium">{t('pod.connectors.setup_help')}</summary>
              <div className="mt-3 grid gap-3 text-muted-foreground">
                <p>
                  {t(`pod.connectors.setup_${model.plugin.value}${model.scheme.value === 'github_app' ? '_app' : ''}`)}
                </p>
                <p>{t('pod.connectors.setup_permissions')}</p>
                <div className="flex flex-wrap gap-x-4 gap-y-2">
                  <a
                    className="underline underline-offset-4"
                    href={
                      model.plugin.value === 'lark'
                        ? model.metadata.value.domain === 'lark'
                          ? 'https://open.larksuite.com/app'
                          : 'https://open.feishu.cn/app'
                        : model.plugin.value === 'github'
                          ? 'https://github.com/settings/developers'
                          : 'https://linear.app/settings/api'
                    }
                    target="_blank"
                    rel="noreferrer">
                    {t('pod.connectors.setup_platform')}
                  </a>
                  <a
                    className="underline underline-offset-4"
                    href={`https://ankole.agentbull.com/${i18n.language}/docs/automation-jobs/`}
                    target="_blank"
                    rel="noreferrer">
                    {t('pod.connectors.setup_docs')}
                  </a>
                </div>
              </div>
            </details>
          )}
          {callbackURL && ['lark_app', 'oauth2'].includes(model.scheme.value) && (
            <div className="grid gap-2">
              <Label htmlFor="connector-callback">{t('pod.connectors.oauth_callback')}</Label>
              <Input
                id="connector-callback"
                readOnly
                value={callbackURL}
                onFocus={event => event.target.select()}
                aria-describedby="connector-callback-help"
              />
              <p id="connector-callback-help" className="text-xs text-muted-foreground">
                {t('pod.connectors.oauth_callback_help')}
              </p>
            </div>
          )}
          <Label htmlFor="connector-name">{t('pod.connectors.name')}</Label>
          <Input
            id="connector-name"
            name="display_name"
            required
            value={model.name.value}
            onChange={event => {
              model.name.value = event.target.value
            }}
          />
          <Label htmlFor="connector-slug">{t('pod.connectors.slug')}</Label>
          <Input
            id="connector-slug"
            name="slug"
            required
            pattern={'[a-z][a-z0-9_\\-]*'}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            aria-describedby="connector-slug-help"
            value={model.slug.value}
            onChange={event => {
              model.slug.value = event.target.value
            }}
          />
          <p id="connector-slug-help" className="text-xs text-muted-foreground">
            {t('pod.connectors.slug_help')}
          </p>
          {fields(connector?.public_fields, false)}
          {fields(connector?.credential_fields, true)}
          {DATABASE_CONNECTORS.includes(model.plugin.value) && <ConnectionAccessFields access={model.access} />}
          <Label className="flex items-center gap-2">
            <Checkbox
              checked={model.isDefault.value}
              onCheckedChange={value => {
                model.isDefault.value = value === true
              }}
            />
            {t('pod.connectors.default')}
          </Label>
          <Button type="submit" disabled={save.isPending}>
            {t('common.save')}
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  )
}
