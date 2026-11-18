import {
  Button,
  Checkbox,
  CopyButton,
  Dialog,
  DialogContent,
  DialogTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toast
} from '@ankole/uikit'
import { isRecord } from '@agentbull/active-support'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { podPublicOrigin } from '../common/browser-context'
import { ConfigField, localizedText, type ConfigFieldDefinition } from '../common/config-fields'
import { ContentError } from './content-primitives'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { requestErrorMessage } from '../common/request-errors'
import * as api from './api/generated/sdk.gen'
import { ConnectionAccessFields } from './connector-connection-access'
import {
  ConnectionEditorModel,
  connectorCredentialFields,
  DATABASE_CONNECTORS,
  larkLinkPreviewRules,
  larkPlatformName,
  type ConnectorConnection,
  type ConnectorDefinition,
  type LarkDomain
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
  const baseID = useId()
  const approvalToolsID = `${baseID}-approval-tools`
  const approvalToolsHelpID = `${baseID}-approval-tools-help`
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
      const parsedApprovalTools = model.approvalToolsText.value
        .split(',')
        .map(item => item.trim())
        .filter(Boolean)
      const publicMetadata: Record<string, unknown> = { ...defaults, ...model.metadata.value }
      if (!DATABASE_CONNECTORS.includes(model.plugin.value)) {
        if (parsedApprovalTools.length > 0 && (publicMetadata.approval ?? 'annotations') === 'annotations') {
          publicMetadata.approval_tools = parsedApprovalTools
        } else {
          delete publicMetadata.approval_tools
        }
      }
      const data = {
        slug: model.slug.value,
        display_name: model.name.value,
        is_default: model.isDefault.value,
        public_metadata: publicMetadata,
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
  const larkDomain: LarkDomain = model.metadata.value.domain === 'lark' ? 'lark' : 'feishu'
  const fields = (items: Record<string, unknown>[] | null | undefined, secret: boolean) =>
    (secret
      ? connectorCredentialFields(items ?? [], model.scheme.value, Boolean(model.editing.value))
      : (items ?? []).filter(field => !Array.isArray(field.schemes) || field.schemes.includes(model.scheme.value))
    ).map(field => {
      const path = String(field.key)
      const values = secret ? model.secret : model.metadata
      const definition: ConfigFieldDefinition = {
        path,
        // Plugins declare either one plain string or a map of localized strings.
        label: localizedMap(field.label, path)!,
        description: localizedMap(field.description),
        type: String(field.type ?? 'string'),
        encrypted: field.secret === true,
        required: field.required === true,
        options: Array.isArray(field.options)
          ? field.options.map(option =>
              typeof option === 'string'
                ? { value: option }
                : {
                    value: String(option.value),
                    label: localizedMap(option.label)
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
                  model.approvalToolsText.value = ''
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
                          {t(`pod.connectors.auth_scheme_${value}`, { defaultValue: humanizeTechnicalLabel(value) })}
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
              <div className="mt-3 grid gap-3 text-fg-secondary">
                <p>
                  {t(`pod.connectors.setup_${model.plugin.value}${model.scheme.value === 'github_app' ? '_app' : ''}`)}
                </p>
                <p>{t('pod.connectors.setup_permissions')}</p>
                <div className="flex flex-wrap gap-x-4 gap-y-2">
                  <a
                    className="underline underline-offset-4"
                    href={
                      model.plugin.value === 'lark'
                        ? larkDomain === 'lark'
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
              <p id="connector-callback-help" className="text-xs text-fg-secondary">
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
          <p id="connector-slug-help" className="text-xs text-fg-secondary">
            {t('pod.connectors.slug_help')}
          </p>
          {fields(connector?.public_fields, false)}
          {model.plugin.value === 'lark' && model.metadata.value.linkPreview === true && (
            <LarkLinkPreviewSetup domain={larkDomain} origin={podPublicOrigin()} />
          )}
          {fields(connector?.credential_fields, true)}
          {DATABASE_CONNECTORS.includes(model.plugin.value) ? (
            <ConnectionAccessFields access={model.access} />
          ) : (
            <div className="grid gap-2">
              <Label>{t('pod.connectors.approval_policy')}</Label>
              <Select
                value={String(model.metadata.value.approval ?? 'annotations')}
                onValueChange={value => {
                  if (!value) return
                  model.metadata.value = { ...model.metadata.value, approval: value }
                }}>
                <SelectTrigger aria-label={t('pod.connectors.approval_policy')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="annotations">{t('pod.connectors.approval_annotations')}</SelectItem>
                  <SelectItem value="all">{t('pod.connectors.approval_all')}</SelectItem>
                  <SelectItem value="none">{t('pod.connectors.approval_none')}</SelectItem>
                </SelectContent>
              </Select>
              {String(model.metadata.value.approval ?? 'annotations') === 'annotations' && (
                <>
                  <Label htmlFor={approvalToolsID}>{t('pod.connectors.approval_tools')}</Label>
                  <Input
                    id={approvalToolsID}
                    autoCapitalize="none"
                    autoCorrect="off"
                    spellCheck={false}
                    aria-describedby={approvalToolsHelpID}
                    value={model.approvalToolsText.value}
                    onChange={event => {
                      model.approvalToolsText.value = event.target.value
                    }}
                  />
                  <p id={approvalToolsHelpID} className="text-xs text-fg-secondary">
                    {t('pod.connectors.approval_tools_help')}
                  </p>
                </>
              )}
            </div>
          )}
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

export function localizedMap(value: unknown, fallback?: string): Record<string, string> | undefined {
  if (isRecord(value)) return value as Record<string, string>
  const text = typeof value === 'string' && value ? value : fallback
  return text ? { default: text } : undefined
}

function LarkLinkPreviewSetup({ domain, origin }: { domain: LarkDomain; origin: string }) {
  const { t, i18n } = useTranslation()
  const baseID = useId()
  const rules = larkLinkPreviewRules(origin)
  if (!rules) return null

  const platform = larkPlatformName(domain, i18n.language)
  const pagesRuleID = `${baseID}-pages-rule`
  const brainRuleID = `${baseID}-brain-rule`
  const hostHintID = `${baseID}-host-hint`
  const describedBy = rules.unsupportedHost ? hostHintID : undefined

  return (
    <div className="grid gap-3 rounded-lg border p-3 text-sm">
      <p className="font-medium">{t('pod.connectors.lark_link_preview_title', { platform })}</p>
      <div className="grid gap-1.5">
        <Label htmlFor={pagesRuleID}>{t('pod.connectors.lark_link_preview_pages_rule')}</Label>
        <div className="flex items-center gap-2">
          <Input
            id={pagesRuleID}
            readOnly
            value={rules.pagesRule}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            aria-describedby={describedBy}
            onFocus={event => event.target.select()}
          />
          <CopyButton
            variant="outline"
            size="icon-sm"
            value={rules.pagesRule}
            label={t('pod.connectors.lark_link_preview_copy_pages_rule')}
            copiedLabel={t('common.copied')}
            onCopyError={error => toast.error(requestErrorMessage(error))}
          />
        </div>
      </div>
      <div className="grid gap-1.5">
        <Label htmlFor={brainRuleID}>{t('pod.connectors.lark_link_preview_brain_rule')}</Label>
        <div className="flex items-center gap-2">
          <Input
            id={brainRuleID}
            readOnly
            value={rules.brainRule}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            aria-describedby={describedBy}
            onFocus={event => event.target.select()}
          />
          <CopyButton
            variant="outline"
            size="icon-sm"
            value={rules.brainRule}
            label={t('pod.connectors.lark_link_preview_copy_brain_rule')}
            copiedLabel={t('common.copied')}
            onCopyError={error => toast.error(requestErrorMessage(error))}
          />
        </div>
      </div>
      {rules.unsupportedHost && (
        <p id={hostHintID} className="text-xs text-fg-secondary">
          {t('pod.connectors.lark_link_preview_local_host_hint', { platform })}
        </p>
      )}
      <ol className="list-decimal space-y-1.5 pl-4 text-xs text-fg-secondary">
        <li>{t('pod.connectors.lark_link_preview_step_rules', { platform })}</li>
        <li>{t('pod.connectors.lark_link_preview_step_callback')}</li>
        <li>{t('pod.connectors.lark_link_preview_step_publish', { platform })}</li>
      </ol>
    </div>
  )
}
