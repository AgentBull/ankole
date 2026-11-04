import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  Checkbox,
  Dialog,
  DialogContent,
  DialogTitle,
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyTitle,
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
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { ConfigField, type ConfigFieldDefinition } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { authenticationRef, podID } from '../common/browser-context'
import { browserSession } from '../common/api/generated/sdk.gen'
import * as api from './api/generated/sdk.gen'
import type { PodConnectorsCatalogResponse } from './api/generated/types.gen'
import { connectorCredentialFields, connectorReturnTo, ConnectorsModel } from './state/connectors'
import { requestErrorCode, requestErrorDetails } from '../common/request-errors'

type Model = InstanceType<typeof ConnectorsModel>
type Connector = NonNullable<PodConnectorsCatalogResponse['connectors']>[number]

export function Connectors() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(ConnectorsModel)
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000
  })
  const client = useQueryClient()
  const key = ['connectors', authenticationRef() ?? '', podID() ?? '']
  const catalog = useQuery({ queryKey: [...key, 'catalog'], queryFn: () => api.podConnectorsCatalog() })
  const connections = useQuery({ queryKey: [...key, 'connections'], queryFn: () => api.podConnectorAuthConfigsList() })
  const accounts = useQuery({ queryKey: [...key, 'accounts'], queryFn: () => api.podConnectorAccountsList() })
  const triggers = useQuery({
    queryKey: [...key, 'triggers'],
    queryFn: () => api.podConnectorTriggersList(),
    refetchInterval: query =>
      query.state.data?.triggers.some(trigger => ['provisioning', 'deleting'].includes(trigger.status)) ? 2000 : false
  })
  const refresh = () => client.invalidateQueries({ queryKey: key })
  const oauth = useMutation({
    mutationFn: ({
      connection,
      scopes,
      subjectKind = 'human',
      trigger
    }: {
      connection: string
      scopes?: string[]
      subjectKind?: 'human' | 'app'
      trigger?: { type: string; scope: string; id?: string }
    }) => {
      return api.podConnectorOAuthBegin({
        body: {
          data: {
            connection,
            scopes,
            return_to: connectorReturnTo(connection, scopes, trigger),
            subject_kind: subjectKind
          }
        }
      })
    },
    onSuccess: result => window.location.assign(result.authorization_url)
  })
  const claim = useMutation({
    mutationFn: (code: string) => api.podConnectorOAuthClaim({ body: { data: { completion_code: code } } }),
    onSuccess: refresh
  })
  const claimed = useRef(false)
  useEffect(() => {
    const url = new URL(window.location.href)
    const code = url.searchParams.get('connector_completion')
    if (!code || claimed.current) return
    claimed.current = true
    claim.mutate(code)
    url.searchParams.delete('connector_completion')
    window.history.replaceState(null, '', url)
  }, [claim.mutate])
  const disconnect = useMutation({
    mutationFn: (id: string) => api.podConnectorAccountsDisconnect({ path: { id } }),
    onSuccess: refresh
  })
  const toggle = useMutation({
    mutationFn: ({ id, status }: { id: string; status: string }) =>
      api.podConnectorAuthConfigsUpdate({ path: { id }, body: { data: { status } } }),
    onSuccess: refresh
  })
  const retry = useMutation({
    mutationFn: (id: string) => api.podConnectorTriggersRetry({ path: { id } }),
    onSuccess: refresh
  })
  const removeTrigger = useMutation({
    mutationFn: (id: string) => api.podConnectorTriggersDelete({ path: { id } }),
    onSuccess: refresh
  })
  const createTrigger = useMutation({
    mutationFn: () =>
      api.podConnectorTriggersCreate({
        body: {
          data: {
            auth_config_id: model.triggerConnection.value!.id,
            trigger_type: model.triggerType.value,
            scope_key: model.triggerScope.value,
            connected_account_id: selectedTrigger?.requires_personal_account ? selectedAccount?.id : undefined
          }
        }
      }),
    onSuccess: async () => {
      model.triggerConnection.value = undefined
      await refresh()
    }
  })
  const save = useMutation({
    mutationFn: async () => {
      const secret = Object.fromEntries(Object.entries(model.secret.value).filter(([, value]) => value !== ''))
      const definition = catalog.data?.connectors?.find(item => item.plugin_id === model.plugin.value)
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
        secret
      }
      if (model.editing.value?.id) {
        return api.podConnectorAuthConfigsUpdate({ path: { id: model.editing.value.id }, body: { data } })
      }
      return api.podConnectorAuthConfigsCreate({
        body: { data: { ...data, plugin_id: model.plugin.value, auth_scheme: model.scheme.value } }
      })
    },
    onSuccess: async () => {
      model.editing.value = undefined
      model.secret.value = {}
      await refresh()
    }
  })
  const params = new URLSearchParams(window.location.search)
  const requested = params.get('connection')
  const authorizationCancelled = params.get('connector_error') === 'oauth_authorization_cancelled'
  const scopes = params.get('scopes')?.split(/[ ,]+/).filter(Boolean)
  const allConnections = connections.data?.connections ?? []
  const allAccounts = accounts.data?.accounts ?? []
  const error =
    catalog.error ??
    connections.error ??
    accounts.error ??
    triggers.error ??
    oauth.error ??
    claim.error ??
    disconnect.error ??
    toggle.error ??
    retry.error ??
    removeTrigger.error
  const triggerTypes =
    catalog.data?.connectors?.find(item => item.plugin_id === model.triggerConnection.value?.plugin_id)
      ?.trigger_types ?? []
  const selectedTrigger = triggerTypes.find(item => item.id === model.triggerType.value)
  const personalAccounts = allAccounts.filter(
    account =>
      account.auth_config_id === model.triggerConnection.value?.id &&
      account.subject_kind === 'human' &&
      account.owner_principal_uid === session.data?.principalUID
  )
  const selectedAccount =
    personalAccounts.find(account => account.id === model.triggerAccount.value) ?? personalAccounts[0]
  const consentRequired = requestErrorCode(createTrigger.error) === 'oauth_consent_required'
  const needsAuthorization =
    selectedTrigger?.requires_personal_account === true && (selectedAccount?.status !== 'active' || consentRequired)
  const restoredDraft = useRef(false)
  useEffect(() => {
    if (restoredDraft.current || !connections.data || !catalog.data) return
    restoredDraft.current = true
    const intent = new URLSearchParams(window.location.search)
    const connection = connections.data.connections.find(item => item.slug === intent.get('connection'))
    const type = intent.get('trigger_type')
    if (
      connection &&
      type &&
      !intent.has('trigger_id') &&
      catalog.data.connectors?.some(
        item => item.plugin_id === connection.plugin_id && item.trigger_types?.some(trigger => trigger.id === type)
      )
    ) {
      model.openTrigger({ connection, type, scope: intent.get('scope_key') ?? '' })
    }
  }, [connections.data, catalog.data, model])
  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto grid w-full max-w-4xl content-start gap-6 px-6 pt-2 pb-10">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl">{t('pod.connectors.title')}</h1>
            <p className="mt-2 text-sm text-muted-foreground">{t('pod.connectors.description')}</p>
          </div>
          {catalog.data?.can_manage && (
            <Button
              onClick={() => {
                save.reset()
                model.edit(null)
              }}>
              {t('pod.connectors.add')}
            </Button>
          )}
        </div>
        <ErrorBlock error={error} />
        {authorizationCancelled && !claim.isSuccess && (
          <p role="status" className="text-sm">
            {t('pod.connectors.authorization_cancelled')}
          </p>
        )}
        {claim.isPending && <p role="status">{t('pod.connectors.finishing')}</p>}
        {claim.isSuccess && (
          <p role="status">
            {params.has('trigger_id')
              ? t('pod.connectors.subscription_retry_authorized')
              : params.has('trigger_type')
                ? t('pod.connectors.subscription_authorized')
                : `${t('pod.connectors.connected')} ${t('pod.connectors.resume_task')}`}
          </p>
        )}
        {claim.isError && (
          <Button variant="outline" onClick={() => claim.mutate(claim.variables!)}>
            {t('common.retry')}
          </Button>
        )}
        {requested && !claim.isSuccess && (
          <p className="text-sm">
            {t('pod.connectors.consent_requested', { connection: requested })}
            {scopes?.length ? ` (${scopes.join(', ')})` : ''}
          </p>
        )}
        {connections.isPending && <p role="status">{t('common.loading')}</p>}
        {connections.isSuccess && allConnections.length === 0 && (
          <Card className="py-0">
            <Empty className="items-start p-6 text-left sm:p-8">
              <EmptyHeader className="max-w-xl items-start">
                <EmptyTitle>{t('pod.connectors.empty_title')}</EmptyTitle>
                <EmptyDescription>
                  {t(catalog.data?.can_manage ? 'pod.connectors.empty_admin' : 'pod.connectors.empty')}
                </EmptyDescription>
              </EmptyHeader>
            </Empty>
          </Card>
        )}
        {allConnections.map(connection => {
          const personal = allAccounts.filter(account => account.auth_config_id === connection.id)
          const definition = catalog.data?.connectors?.find(item => item.plugin_id === connection.plugin_id)
          const supportsOAuth =
            ['lark', 'github', 'linear'].includes(connection.plugin_id ?? '') && connection.auth_scheme !== 'github_app'
          return (
            <Card key={connection.id} className="[overflow-wrap:anywhere]">
              <CardHeader>
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="font-medium">{connection.display_name || connection.slug}</h2>
                  <Badge variant="secondary">{definition?.display_name || connection.plugin_id}</Badge>
                  <Badge variant="outline">
                    {t(`pod.connectors.status.${connection.status}`, { defaultValue: connection.status ?? '' })}
                  </Badge>
                  {connection.is_default && <Badge variant="outline">{t('pod.connectors.default')}</Badge>}
                </div>
                <p className="text-xs text-muted-foreground">{connection.slug}</p>
              </CardHeader>
              <CardContent className="grid gap-4">
                {personal.map(account => (
                  <div key={account.id} className="flex flex-wrap items-center justify-between gap-3 text-sm">
                    <div>
                      <p>
                        {account.subject_kind === 'app' ? `${t('pod.connectors.application_account')} · ` : ''}
                        {account.owner_principal_uid && account.owner_principal_uid !== session.data?.principalUID
                          ? `${account.owner_principal_uid} · `
                          : ''}
                        {typeof account.public_metadata?.name === 'string'
                          ? account.public_metadata.name
                          : account.external_subject_id || account.account_key}
                      </p>
                      <p className="text-muted-foreground">
                        {t(`pod.connectors.status.${account.status}`, { defaultValue: account.status ?? '' })}
                        {account.granted_scopes?.length ? ` · ${account.granted_scopes.join(', ')}` : ''}
                      </p>
                      {account.last_error && (
                        <p className="text-destructive">
                          {String(account.last_error.message ?? account.last_error.code ?? '')}
                        </p>
                      )}
                    </div>
                    {account.status === 'active' && (
                      <Button
                        variant="outline"
                        disabled={disconnect.isPending}
                        onClick={() => disconnect.mutate(account.id!)}>
                        {t('pod.connectors.disconnect')}
                      </Button>
                    )}
                  </div>
                ))}
                <div className="flex flex-wrap gap-2">
                  {supportsOAuth && connection.status === 'active' && (
                    <Button
                      variant={requested === connection.slug ? 'default' : 'outline'}
                      disabled={oauth.isPending}
                      onClick={() =>
                        oauth.mutate({
                          connection: connection.slug!,
                          scopes: requested === connection.slug ? scopes : undefined
                        })
                      }>
                      {t(
                        personal.some(
                          account =>
                            account.subject_kind === 'human' &&
                            account.owner_principal_uid === session.data?.principalUID &&
                            account.status === 'active'
                        )
                          ? 'pod.connectors.reconnect'
                          : 'pod.connectors.connect'
                      )}
                    </Button>
                  )}
                  {supportsOAuth &&
                    connection.auth_scheme === 'oauth2' &&
                    connection.status === 'active' &&
                    catalog.data?.can_manage && (
                      <Button
                        variant="outline"
                        disabled={oauth.isPending}
                        onClick={() => oauth.mutate({ connection: connection.slug!, subjectKind: 'app' })}>
                        {t('pod.connectors.connect_application')}
                      </Button>
                    )}
                  {(definition?.trigger_types?.length ?? 0) > 0 &&
                    connection.status === 'active' &&
                    (catalog.data?.can_manage ||
                      definition?.trigger_types?.some(type => type.requires_personal_account)) && (
                      <Button
                        variant="outline"
                        onClick={() => {
                          createTrigger.reset()
                          model.openTrigger({ connection })
                        }}>
                        {t('pod.connectors.subscribe')}
                      </Button>
                    )}
                  {catalog.data?.can_manage && (
                    <>
                      <Button
                        variant="outline"
                        onClick={() => {
                          save.reset()
                          model.edit(connection)
                        }}>
                        {t('pod.connectors.edit')}
                      </Button>
                      <Button
                        variant="outline"
                        disabled={toggle.isPending}
                        onClick={() =>
                          toggle.mutate({
                            id: connection.id!,
                            status: connection.status === 'active' ? 'disabled' : 'active'
                          })
                        }>
                        {t(connection.status === 'active' ? 'pod.connectors.disable' : 'pod.connectors.enable')}
                      </Button>
                    </>
                  )}
                </div>
              </CardContent>
            </Card>
          )
        })}
        {(triggers.data?.triggers.length ?? 0) > 0 && (
          <section className="grid gap-3">
            <h2 className="text-lg">{t('pod.connectors.subscriptions')}</h2>
            <p className="text-sm text-muted-foreground">{t('pod.connectors.subscription_next_step')}</p>
            {triggers.data!.triggers.map(trigger => {
              const connection = allConnections.find(item => item.id === trigger.auth_config_id)
              const account = allAccounts.find(item => item.id === trigger.connected_account_id)
              const definition = catalog.data?.connectors
                ?.find(item => item.plugin_id === connection?.plugin_id)
                ?.trigger_types?.find(item => item.id === trigger.trigger_type)
              const retryConsent =
                retry.variables === trigger.id && requestErrorCode(retry.error) === 'oauth_consent_required'
              const needsConsent =
                definition?.requires_personal_account === true &&
                (account?.status !== 'active' || retryConsent || trigger.last_error?.code === 'oauth_consent_required')
              const canAuthorize = account?.owner_principal_uid === session.data?.principalUID
              return (
                <Card key={trigger.id} className="[overflow-wrap:anywhere]">
                  <CardContent className="flex flex-wrap items-center justify-between gap-3 pt-5">
                    <div>
                      <p>
                        {trigger.trigger_type} · {trigger.scope_key}
                      </p>
                      <p className="text-sm text-muted-foreground">
                        {allConnections.find(connection => connection.id === trigger.auth_config_id)?.display_name}
                      </p>
                      <p className="text-sm text-muted-foreground">
                        {t(`pod.connectors.status.${trigger.status}`, { defaultValue: trigger.status ?? '' })}
                      </p>
                      <p className="mt-1 break-all font-mono text-xs select-all">{trigger.config_ref}</p>
                      {trigger.last_error && (
                        <p className="text-sm text-destructive">
                          {String(trigger.last_error.message ?? trigger.last_error.code ?? '')}
                        </p>
                      )}
                    </div>
                    {needsConsent && canAuthorize && connection && (
                      <Button
                        disabled={oauth.isPending}
                        onClick={() =>
                          oauth.mutate({
                            connection: connection.slug!,
                            scopes: (definition?.oauth_scopes ?? []) as string[],
                            trigger: { type: trigger.trigger_type, scope: trigger.scope_key, id: trigger.id }
                          })
                        }>
                        {t('pod.connectors.authorize_subscription')}
                      </Button>
                    )}
                    {needsConsent && !canAuthorize && (
                      <p className="text-sm">
                        {t('pod.connectors.subscription_authorize_owner', {
                          owner: account?.owner_principal_uid ?? ''
                        })}
                      </p>
                    )}
                    <Button
                      variant="outline"
                      disabled={retry.isPending || claim.isPending}
                      onClick={() => retry.mutate(trigger.id!)}>
                      {t('common.retry')}
                    </Button>
                    <Button
                      variant="outline"
                      disabled={removeTrigger.isPending}
                      onClick={() => removeTrigger.mutate(trigger.id!)}>
                      {t('common.delete')}
                    </Button>
                  </CardContent>
                </Card>
              )
            })}
          </section>
        )}
        <Dialog
          open={Boolean(model.triggerConnection.value)}
          onOpenChange={open => {
            if (!open) model.triggerConnection.value = undefined
          }}>
          <DialogContent closeLabel={t('common.close')}>
            <DialogTitle>{t('pod.connectors.subscribe')}</DialogTitle>
            <p className="text-sm text-muted-foreground">{t('pod.connectors.subscription_help')}</p>
            <ErrorBlock error={consentRequired ? undefined : createTrigger.error} />
            <ErrorBlock error={oauth.error ?? claim.error} />
            {claim.isPending && <p role="status">{t('pod.connectors.finishing')}</p>}
            {claim.isError && (
              <Button variant="outline" onClick={() => claim.mutate(claim.variables!)}>
                {t('common.retry')}
              </Button>
            )}
            {authorizationCancelled && <p role="status">{t('pod.connectors.subscription_authorization_cancelled')}</p>}
            {claim.isSuccess && <p role="status">{t('pod.connectors.subscription_authorized')}</p>}
            {needsAuthorization && <p role="status">{t('pod.connectors.subscription_authorize_help')}</p>}
            <form
              className="grid gap-4"
              onSubmit={event => {
                event.preventDefault()
                if (needsAuthorization) {
                  const details = requestErrorDetails(createTrigger.error)
                  oauth.mutate({
                    connection: model.triggerConnection.value!.slug!,
                    scopes: (Array.isArray(details.scopes)
                      ? details.scopes
                      : (selectedTrigger?.oauth_scopes ?? [])) as string[],
                    trigger: { type: model.triggerType.value, scope: model.triggerScope.value }
                  })
                } else {
                  createTrigger.mutate()
                }
              }}>
              <Label>{t('pod.connectors.event_type')}</Label>
              <Select
                value={model.triggerType.value}
                required
                onValueChange={value => {
                  model.triggerType.value = value ?? ''
                  model.triggerAccount.value = ''
                  createTrigger.reset()
                }}>
                <SelectTrigger aria-label={t('pod.connectors.event_type')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {triggerTypes
                    .filter(type => catalog.data?.can_manage || type.requires_personal_account)
                    .map(type => (
                      <SelectItem key={String(type.id)} value={String(type.id)}>
                        {String(type.label)}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
              <Label htmlFor="connector-scope">
                {String(selectedTrigger?.scope_label ?? t('pod.connectors.resource'))}
              </Label>
              <Input
                id="connector-scope"
                name="scope"
                required
                value={model.triggerScope.value}
                onChange={event => {
                  model.triggerScope.value = event.target.value
                }}
              />
              {selectedTrigger?.requires_personal_account === true && personalAccounts.length > 0 && (
                <>
                  <Label>{t('pod.connectors.account')}</Label>
                  <Select
                    required
                    value={selectedAccount?.id ?? ''}
                    onValueChange={value => {
                      model.triggerAccount.value = value ?? ''
                      createTrigger.reset()
                    }}>
                    <SelectTrigger aria-label={t('pod.connectors.account')}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {personalAccounts.map(account => (
                        <SelectItem key={account.id} value={account.id}>
                          {typeof account.public_metadata?.name === 'string'
                            ? account.public_metadata.name
                            : account.external_subject_id || account.account_key}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </>
              )}
              <Button
                type="submit"
                disabled={createTrigger.isPending || oauth.isPending || claim.isPending || accounts.isPending}>
                {t(needsAuthorization ? 'pod.connectors.authorize_subscription' : 'pod.connectors.subscribe')}
              </Button>
            </form>
          </DialogContent>
        </Dialog>
        <Dialog
          open={model.editing.value !== undefined}
          onOpenChange={open => {
            if (!open) {
              model.editing.value = undefined
              model.secret.value = {}
            }
          }}>
          <DialogContent closeLabel={t('common.close')} className="max-h-[85dvh] overflow-y-auto">
            <DialogTitle>{t(model.editing.value ? 'pod.connectors.edit' : 'pod.connectors.add')}</DialogTitle>
            <ErrorBlock error={save.error} />
            <ConnectionForm
              model={model}
              connectors={catalog.data?.connectors ?? []}
              callbackURL={catalog.data?.oauth_callback_url}
              pending={save.isPending}
              submit={() => save.mutate()}
            />
          </DialogContent>
        </Dialog>
      </div>
    </div>
  )
}

function ConnectionForm({
  model,
  connectors,
  callbackURL,
  pending,
  submit
}: {
  model: Model
  connectors: Connector[]
  callbackURL?: string
  pending: boolean
  submit(): void
}) {
  useSignals()
  const { t, i18n } = useTranslation()
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
        label: { default: String(field.label || path) },
        type: String(field.type ?? 'string'),
        encrypted: field.secret === true,
        required: field.required === true,
        options: Array.isArray(field.options)
          ? field.options.map(option =>
              typeof option === 'string' ? { value: option } : { value: String(option.value), label: option.label }
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
    <form
      className="grid gap-4"
      onSubmit={event => {
        event.preventDefault()
        submit()
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
                  {item.display_name}
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
      <Label className="flex items-center gap-2">
        <Checkbox
          checked={model.isDefault.value}
          onCheckedChange={value => {
            model.isDefault.value = value === true
          }}
        />
        {t('pod.connectors.default')}
      </Label>
      <Button type="submit" disabled={pending}>
        {t('common.save')}
      </Button>
    </form>
  )
}
