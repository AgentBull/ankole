import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
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
import { ContentSkeleton } from './content-primitives'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ConfigFields,
  defaultConfig,
  localizedText,
  setPath,
  type ConfigFieldDefinition
} from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import { authenticationRef, podID } from '../common/browser-context'
import { localReturnPath } from '../common/pod-url'
import { browserSession } from '../common/api/generated/sdk.gen'
import * as api from './api/generated/sdk.gen'
import { ConnectionEditorDialog } from './connector-connection-dialog'
import { CredentialBindingDialog } from './connector-credential-dialog'
import {
  connectorAutomationContext,
  connectorAutomationReturnTo,
  connectorFailureMessage,
  connectorReturnTo,
  connectorTriggerConfigFromURL,
  ConnectorsModel,
  type ConnectorConnection,
  type ConnectorDefinition
} from './state/connectors'
import { requestErrorCode, requestErrorDetails } from '../common/request-errors'

export function Connectors() {
  useSignals()
  const { t, i18n } = useTranslation()
  const model = useModel(ConnectorsModel)
  const params = new URLSearchParams(window.location.search)
  const originalTaskPath = localReturnPath(params.get('intent'), window.location.origin)
  const automation = connectorAutomationContext(params)
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000
  })
  const client = useQueryClient()
  const key = ['connectors', authenticationRef() ?? '', podID() ?? '']
  const catalog = useQuery({ queryKey: [...key, 'catalog'], queryFn: () => api.podConnectorsCatalog() })
  const connections = useQuery({ queryKey: [...key, 'connections'], queryFn: () => api.podConnectorAuthConfigsList() })
  const accounts = useQuery({
    queryKey: [...key, 'accounts', 'mine'],
    queryFn: () => api.podConnectorAccountsList({ query: { scope: 'mine' } })
  })
  const teamAccounts = useQuery({
    queryKey: [...key, 'accounts', 'team'],
    queryFn: () => api.podConnectorAccountsList({ query: { scope: 'team' } })
  })
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
      trigger?: { type: string; scope: string; id?: string; config?: Record<string, unknown> }
    }) => {
      return api.podConnectorOAuthBegin({
        body: {
          data: {
            connection,
            scopes,
            return_to: connectorReturnTo({
              connection,
              scopes,
              trigger,
              automation,
              subjectKind,
              intent: params.get('intent')
            }),
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
          data: model.triggerAttributes(defaultConfig(triggerConfigFields), selectedAccount?.id, fixedTriggerScope)
        }
      }),
    onSuccess: async () => {
      model.triggerConnection.value = undefined
      await refresh()
    }
  })
  const requested = params.get('connection')
  const credentialMode = params.get('auth_mode')
  const requestedSubjectKind =
    credentialMode === 'team_credentials' || params.get('subject_kind') === 'app' ? 'app' : 'human'
  const authorizationCancelled = params.get('connector_error') === 'oauth_authorization_cancelled'
  const scopes = params.get('scopes')?.split(/[ ,]+/).filter(Boolean)
  const allConnections = connections.data?.connections ?? []
  const allAccounts = [...(accounts.data?.accounts ?? []), ...(teamAccounts.data?.accounts ?? [])]
  const error =
    catalog.error ??
    connections.error ??
    accounts.error ??
    teamAccounts.error ??
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
  const fixedTriggerScope =
    typeof selectedTrigger?.fixed_scope_key === 'string' ? selectedTrigger.fixed_scope_key : undefined
  const triggerConfigFields = (selectedTrigger?.config_fields ?? []) as ConfigFieldDefinition[]
  const triggerConfig = { ...defaultConfig(triggerConfigFields), ...model.triggerConfig.value }
  const triggerScopeOptions = Array.isArray(selectedTrigger?.scope_options)
    ? selectedTrigger.scope_options.map(String)
    : []
  const triggerAccounts = allAccounts.filter(
    account =>
      account.auth_config_id ===
        allConnections.find(connection => connection.slug === model.triggerConnection.value?.slug)?.id &&
      account.subject_kind === model.triggerSubject.value &&
      (account.subject_kind === 'app' || account.owner_principal_uid === session.data?.principalUID)
  )
  const selectedAccount =
    triggerAccounts.find(account => account.id === model.triggerAccount.value) ?? triggerAccounts[0]
  const consentRequired = requestErrorCode(createTrigger.error) === 'oauth_consent_required'
  const needsAuthorization =
    (selectedTrigger?.requires_personal_account === true ||
      selectedTrigger?.supports_personal_account === true ||
      usesTokenCredentials(model.triggerConnection.value)) &&
    (selectedAccount?.status !== 'active' || consentRequired)
  const restoredDraft = useRef(false)
  const openedCredentialIntent = useRef(false)
  useEffect(() => {
    if (
      openedCredentialIntent.current ||
      !connections.data ||
      !catalog.data ||
      !['personal_credentials', 'team_credentials'].includes(credentialMode ?? '')
    ) {
      return
    }
    const connection = connections.data.connections.find(item => item.slug === requested)
    const canBind =
      credentialMode === 'team_credentials'
        ? catalog.data.can_manage && usesTokenCredentials(connection)
        : catalog.data.connectors?.some(item => item.plugin_id === connection?.plugin_id && item.personal_credentials)
    if (connection && canBind) {
      openedCredentialIntent.current = true
      model.bindCredentials(connection, credentialMode === 'team_credentials' ? 'app' : 'human')
    }
  }, [connections.data, catalog.data, requested, credentialMode, model])
  const authorizationIntentStarted = useRef(
    params.has('connector_completion') || params.has('connector_error') || params.has('trigger_type')
  )
  useEffect(() => {
    if (
      authorizationIntentStarted.current ||
      ['personal_credentials', 'team_credentials'].includes(credentialMode ?? '') ||
      !requested ||
      !connections.data ||
      !catalog.data ||
      !session.isSuccess
    ) {
      return
    }
    const connection = connections.data.connections.find(item => item.slug === requested)
    if (!connection || !supportsOAuthAccount(connection) || connection.status !== 'active') return
    if (requestedSubjectKind === 'app' && !catalog.data.can_manage) return
    authorizationIntentStarted.current = true
    oauth.mutate({ connection: connection.slug, scopes, subjectKind: requestedSubjectKind })
  }, [connections.data, catalog.data, session.isSuccess, requested, requestedSubjectKind, credentialMode])
  const focusedTarget = useRef(false)
  useEffect(() => {
    if (focusedTarget.current || !connections.data || !triggers.data) return
    if (params.has('trigger_type') && !params.has('trigger_id')) return
    if (model.triggerConnection.value || model.credentialConnection.value || model.editing.value !== undefined) return
    const target = params.get('trigger_id') ?? (requested ? `${requestedSubjectKind}-${requested}` : undefined)
    if (!target) return
    const element = document.getElementById(`connector-${target}`)
    if (element) {
      focusedTarget.current = true
      element.scrollIntoView({ block: 'center' })
      element.focus({ preventScroll: true })
    }
  }, [connections.data, triggers.data, requested])
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
      model.openTrigger({
        connection,
        type,
        scope: intent.get('scope_key') ?? '',
        config: connectorTriggerConfigFromURL(intent),
        subject: requestedSubjectKind
      })
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
                model.edit(null)
              }}>
              {t('pod.connectors.add')}
            </Button>
          )}
        </div>
        {automation && (
          <Link
            className="justify-self-start text-sm underline underline-offset-4"
            to={connectorAutomationReturnTo(automation)}>
            {t('pod.connectors.return_to_automation')}
          </Link>
        )}
        <ErrorBlock error={error} />
        {automation && createTrigger.data && (
          <p role="status" className="text-sm">
            {t('pod.connectors.subscription_created')}{' '}
            <Link
              className="underline underline-offset-4"
              to={connectorAutomationReturnTo(automation, createTrigger.data.trigger.config_ref)}>
              {t('pod.connectors.use_in_automation')}
            </Link>
          </p>
        )}
        {authorizationCancelled && !claim.isSuccess && !model.credentialsBound.value && (
          <p role="status" className="text-sm">
            {t('pod.connectors.authorization_cancelled')}
          </p>
        )}
        {claim.isPending && <p role="status">{t('pod.connectors.finishing')}</p>}
        {(claim.isSuccess || model.credentialsBound.value) && (
          <p role="status">
            {params.has('trigger_id')
              ? t('pod.connectors.subscription_retry_authorized')
              : params.has('trigger_type')
                ? t('pod.connectors.subscription_authorized')
                : `${t('pod.connectors.connected')} ${originalTaskPath ? '' : t('pod.connectors.resume_task')}`}
            {originalTaskPath && (
              <>
                {' '}
                <Link className="underline underline-offset-4" to={originalTaskPath}>
                  {t('pod.connectors.return_to_task')}
                </Link>
              </>
            )}
          </p>
        )}
        {claim.isError && (
          <Button variant="outline" onClick={() => claim.mutate(claim.variables!)}>
            {t('common.retry')}
          </Button>
        )}
        {requested && !claim.isSuccess && !model.credentialsBound.value && (
          <p className="text-sm">
            {requestedSubjectKind === 'app' ? `${t('pod.connectors.application_account')} · ` : ''}
            {t('pod.connectors.consent_requested', { connection: requested })}
            {scopes?.length ? ` (${scopes.join(', ')})` : ''}
            {requestedSubjectKind === 'app' && catalog.isSuccess && !catalog.data?.can_manage && (
              <> {t('pod.connectors.application_authorize_admin')}</>
            )}
          </p>
        )}
        {connections.isPending && <ContentSkeleton variant="list" rows={3} />}
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
        {(['human', 'app'] as const).map(subjectKind => (
          <section key={subjectKind} className="grid gap-4" aria-labelledby={`connectors-${subjectKind}`}>
            <div>
              <h2 id={`connectors-${subjectKind}`} className="text-lg">
                {t(subjectKind === 'human' ? 'pod.connectors.personal_title' : 'pod.connectors.team_title')}
              </h2>
              <p className="mt-1 text-sm text-muted-foreground">
                {t(subjectKind === 'human' ? 'pod.connectors.personal_description' : 'pod.connectors.team_description')}
              </p>
            </div>
            {allConnections
              .filter(
                connection =>
                  subjectKind === 'app' || supportsPersonalAccount(connection, catalog.data?.connectors ?? [])
              )
              .map(connection => {
                const personal = allAccounts.filter(
                  account =>
                    account.auth_config_id === connection.id &&
                    account.subject_kind === subjectKind &&
                    (subjectKind === 'app' || account.owner_principal_uid === session.data?.principalUID)
                )
                const definition = catalog.data?.connectors?.find(item => item.plugin_id === connection.plugin_id)
                const supportsOAuth = supportsOAuthAccount(connection)
                return (
                  <Card
                    key={connection.slug}
                    id={`connector-${subjectKind}-${connection.slug}`}
                    tabIndex={-1}
                    className="scroll-m-6 [overflow-wrap:anywhere] focus-visible:outline-2 focus-visible:outline-ring">
                    <CardHeader>
                      <div className="flex flex-wrap items-center gap-2">
                        <h3 className="font-medium">{connection.display_name || connection.slug}</h3>
                        <Badge variant="secondary">
                          {localizedText(connection.platform_name, i18n.language) ??
                            localizedText(definition?.display_name, i18n.language) ??
                            connection.plugin_id}
                        </Badge>
                        <Badge variant="outline">
                          {t(`pod.connectors.status.${connection.status}`, { defaultValue: connection.status ?? '' })}
                        </Badge>
                        {connection.is_default && <Badge variant="outline">{t('pod.connectors.default')}</Badge>}
                      </div>
                      {subjectKind === 'app' && <p className="text-xs text-muted-foreground">{connection.slug}</p>}
                    </CardHeader>
                    <CardContent className="grid gap-4">
                      {personal.length === 0 && accounts.isSuccess && teamAccounts.isSuccess && session.isSuccess && (
                        <p className="text-sm text-muted-foreground">
                          {t(
                            subjectKind === 'human'
                              ? 'pod.connectors.personal_empty'
                              : catalog.data?.can_manage
                                ? 'pod.connectors.team_empty'
                                : 'pod.connectors.team_empty_member'
                          )}
                        </p>
                      )}
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
                              <p className="text-destructive">{connectorFailureMessage(account.last_error)}</p>
                            )}
                          </div>
                          {account.status === 'active' && (subjectKind === 'human' || catalog.data?.can_manage) && (
                            <Button
                              variant="outline"
                              disabled={disconnect.isPending}
                              onClick={() => disconnect.mutate(account.id!)}>
                              {t('pod.connectors.disconnect')}
                            </Button>
                          )}
                        </div>
                      ))}
                      {connection.plugin_id === 'salesforce' && (
                        <p className="text-sm text-muted-foreground">{t('pod.connectors.guide_salesforce')}</p>
                      )}
                      <div className="flex flex-wrap gap-2">
                        {((subjectKind === 'human' && definition?.personal_credentials) ||
                          (subjectKind === 'app' && catalog.data?.can_manage && usesTokenCredentials(connection))) &&
                          connection.status === 'active' && (
                            <Button
                              variant={requested === connection.slug ? 'default' : 'outline'}
                              onClick={() => {
                                model.bindCredentials(connection, subjectKind)
                              }}>
                              {t(
                                subjectKind === 'human'
                                  ? 'pod.connectors.bind_personal_token'
                                  : 'pod.connectors.bind_team_credentials'
                              )}
                            </Button>
                          )}
                        {subjectKind === 'human' && supportsOAuth && connection.status === 'active' && (
                          <Button
                            variant={
                              requested === connection.slug && requestedSubjectKind === 'human' ? 'default' : 'outline'
                            }
                            disabled={oauth.isPending}
                            onClick={() =>
                              oauth.mutate({
                                connection: connection.slug!,
                                scopes:
                                  requested === connection.slug && requestedSubjectKind === 'human' ? scopes : undefined
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
                        {subjectKind === 'app' &&
                          supportsOAuth &&
                          connection.auth_scheme === 'oauth2' &&
                          connection.status === 'active' &&
                          catalog.data?.can_manage && (
                            <Button
                              variant={
                                requested === connection.slug && requestedSubjectKind === 'app' ? 'default' : 'outline'
                              }
                              disabled={oauth.isPending}
                              onClick={() =>
                                oauth.mutate({
                                  connection: connection.slug!,
                                  subjectKind: 'app',
                                  scopes:
                                    requested === connection.slug && requestedSubjectKind === 'app' ? scopes : undefined
                                })
                              }>
                              {t('pod.connectors.connect_application')}
                            </Button>
                          )}
                        {(definition?.trigger_types?.length ?? 0) > 0 &&
                          connection.status === 'active' &&
                          (subjectKind === 'app'
                            ? catalog.data?.can_manage
                            : definition?.trigger_types?.some(
                                type => type.requires_personal_account || type.supports_personal_account
                              )) && (
                            <Button
                              variant="outline"
                              onClick={() => {
                                createTrigger.reset()
                                model.openTrigger({ connection, subject: subjectKind })
                              }}>
                              {t('pod.connectors.subscribe')}
                            </Button>
                          )}
                        {subjectKind === 'app' && catalog.data?.can_manage && connection.mode !== 'cloud' && (
                          <>
                            <Button
                              variant="outline"
                              onClick={() => {
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
          </section>
        ))}
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
                (definition?.requires_personal_account === true ||
                  definition?.supports_personal_account === true ||
                  usesTokenCredentials(connection)) &&
                ((trigger.connected_account_status ?? account?.status) !== 'active' ||
                  retryConsent ||
                  trigger.last_error?.code === 'oauth_consent_required')
              const owner = trigger.owner_principal_uid ?? account?.owner_principal_uid
              const accountSubject = account?.subject_kind === 'human' || owner ? 'human' : 'app'
              const canAuthorize =
                accountSubject === 'app' ? catalog.data?.can_manage : owner === session.data?.principalUID
              const callbackURL =
                trigger.last_error?.callback_url ??
                (trigger.plugin_id === 'sentry' ? trigger.external_subscription_id : undefined)
              return (
                <Card
                  key={trigger.id}
                  id={`connector-${trigger.id}`}
                  tabIndex={-1}
                  className="scroll-m-6 [overflow-wrap:anywhere] focus-visible:outline-2 focus-visible:outline-ring">
                  <CardContent className="flex flex-wrap items-center justify-between gap-3 pt-5">
                    <div>
                      <p>
                        {String(definition?.label ?? trigger.trigger_type)} · {trigger.scope_key}
                      </p>
                      <p className="text-sm text-muted-foreground">
                        {allConnections.find(connection => connection.id === trigger.auth_config_id)?.display_name}
                      </p>
                      <p className="text-sm text-muted-foreground">
                        {t(`pod.connectors.status.${trigger.status}`, { defaultValue: trigger.status ?? '' })}
                      </p>
                      <p className="mt-1 break-all font-mono text-xs select-all">{trigger.config_ref}</p>
                      {trigger.last_error && (
                        <p className="text-sm text-destructive">{connectorFailureMessage(trigger.last_error)}</p>
                      )}
                      {typeof callbackURL === 'string' && (
                        <div className="mt-3 grid gap-2">
                          <Label htmlFor={`callback-${trigger.id}`}>{t('pod.connectors.webhook_callback')}</Label>
                          <Input
                            id={`callback-${trigger.id}`}
                            readOnly
                            value={callbackURL}
                            onFocus={event => event.target.select()}
                          />
                          <p className="text-sm text-muted-foreground">{t('pod.connectors.sentry_webhook_setup')}</p>
                        </div>
                      )}
                    </div>
                    {needsConsent && canAuthorize && connection && (
                      <Button
                        disabled={oauth.isPending}
                        onClick={() => {
                          if (usesTokenCredentials(connection)) {
                            model.bindCredentials(connection, accountSubject)
                          } else {
                            oauth.mutate({
                              connection: connection.slug!,
                              subjectKind: accountSubject,
                              scopes: (definition?.oauth_scopes ?? []) as string[],
                              trigger: {
                                type: trigger.trigger_type,
                                scope: trigger.scope_key,
                                id: trigger.id,
                                config: trigger.config
                              }
                            })
                          }
                        }}>
                        {t('pod.connectors.authorize_subscription')}
                      </Button>
                    )}
                    {needsConsent && !canAuthorize && (
                      <p className="text-sm">
                        {t('pod.connectors.subscription_authorize_owner', {
                          owner: owner ?? ''
                        })}
                      </p>
                    )}
                    {catalog.data?.can_manage &&
                      owner &&
                      owner !== session.data?.principalUID &&
                      trigger.connected_account_id && (
                        <Button
                          variant="outline"
                          disabled={disconnect.isPending}
                          onClick={() => disconnect.mutate(trigger.connected_account_id!)}>
                          {t('pod.connectors.disconnect_owner', { owner })}
                        </Button>
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
                    {automation && (
                      <Link
                        className="text-sm underline underline-offset-4"
                        to={connectorAutomationReturnTo(automation, trigger.config_ref)}>
                        {t('pod.connectors.use_in_automation')}
                      </Link>
                    )}
                  </CardContent>
                </Card>
              )
            })}
          </section>
        )}
        <Dialog
          open={Boolean(model.triggerConnection.value) && !model.credentialConnection.value}
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
                if (
                  needsAuthorization &&
                  model.triggerConnection.value &&
                  usesTokenCredentials(model.triggerConnection.value)
                ) {
                  model.bindCredentials(model.triggerConnection.value, model.triggerSubject.value)
                } else if (needsAuthorization) {
                  const details = requestErrorDetails(createTrigger.error)
                  oauth.mutate({
                    connection: model.triggerConnection.value!.slug!,
                    subjectKind: model.triggerSubject.value,
                    scopes: (Array.isArray(details.scopes)
                      ? details.scopes
                      : (selectedTrigger?.oauth_scopes ?? [])) as string[],
                    trigger: {
                      type: model.triggerType.value,
                      scope: fixedTriggerScope ?? model.triggerScope.value,
                      config: triggerConfig
                    }
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
                  if (!value) return
                  model.triggerType.value = value
                  model.triggerConfig.value = {}
                  const scopeOptions = triggerTypes.find(type => type.id === value)?.scope_options
                  if (Array.isArray(scopeOptions) && !scopeOptions.includes(model.triggerScope.value)) {
                    model.triggerScope.value = ''
                  }
                  model.triggerAccount.value = ''
                  createTrigger.reset()
                }}>
                <SelectTrigger aria-label={t('pod.connectors.event_type')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {triggerTypes
                    .filter(type =>
                      model.triggerSubject.value === 'app'
                        ? catalog.data?.can_manage && !type.requires_personal_account
                        : type.requires_personal_account || type.supports_personal_account
                    )
                    .map(type => (
                      <SelectItem key={String(type.id)} value={String(type.id)}>
                        {String(type.label)}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
              <ConfigFields
                fields={triggerConfigFields}
                config={triggerConfig}
                locale={i18n.language}
                fieldGroupClassName="grid gap-4"
                onChange={(path, value) => {
                  model.triggerConfig.value = setPath(model.triggerConfig.value, path, value)
                }}
              />
              {!fixedTriggerScope && (
                <>
                  <Label htmlFor="connector-scope">
                    {String(selectedTrigger?.scope_label ?? t('pod.connectors.resource'))}
                  </Label>
                  {triggerScopeOptions.length > 0 ? (
                    <Select
                      name="scope"
                      required
                      value={model.triggerScope.value}
                      onValueChange={value => {
                        if (value) model.triggerScope.value = value
                      }}>
                      <SelectTrigger id="connector-scope">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {triggerScopeOptions.map(value => (
                          <SelectItem key={value} value={value}>
                            {value}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  ) : (
                    <Input
                      id="connector-scope"
                      name="scope"
                      required
                      value={model.triggerScope.value}
                      onChange={event => {
                        model.triggerScope.value = event.target.value
                      }}
                    />
                  )}
                </>
              )}
              {(selectedTrigger?.requires_personal_account === true ||
                selectedTrigger?.supports_personal_account === true ||
                usesTokenCredentials(model.triggerConnection.value)) &&
                triggerAccounts.length > 0 && (
                  <>
                    <Label>
                      {t(
                        model.triggerSubject.value === 'human'
                          ? 'pod.connectors.account'
                          : 'pod.connectors.application_account'
                      )}
                    </Label>
                    <Select
                      required
                      value={selectedAccount?.id ?? ''}
                      onValueChange={value => {
                        if (!value) return
                        model.triggerAccount.value = value
                        createTrigger.reset()
                      }}>
                      <SelectTrigger aria-label={t('pod.connectors.account')}>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {triggerAccounts.map(account => (
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
        {model.credentialConnection.value && (
          <CredentialBindingDialog
            connection={model.credentialConnection.value}
            subject={model.credentialSubject.value}
            definition={catalog.data?.connectors?.find(
              item => item.plugin_id === model.credentialConnection.value?.plugin_id
            )}
            onClose={() => {
              model.credentialConnection.value = undefined
            }}
            onBound={async () => {
              model.credentialConnection.value = undefined
              model.credentialsBound.value = true
              await refresh()
            }}
          />
        )}
        {model.editing.value !== undefined && (
          <ConnectionEditorDialog
            connection={model.editing.value}
            connectors={catalog.data?.connectors ?? []}
            callbackURL={catalog.data?.oauth_callback_url}
            onClose={() => {
              model.editing.value = undefined
            }}
            onRefresh={refresh}
          />
        )}
      </div>
    </div>
  )
}

function usesTokenCredentials(connection?: ConnectorConnection) {
  return ['api_token', 'personal_token'].includes(connection?.auth_scheme ?? '')
}

function supportsOAuthAccount(connection: ConnectorConnection) {
  return (
    connection.auth_scheme === 'oauth2' ||
    (['lark', 'github', 'linear'].includes(connection.plugin_id ?? '') && connection.auth_scheme !== 'github_app')
  )
}

function supportsPersonalAccount(connection: ConnectorConnection, connectors: ConnectorDefinition[]) {
  return (
    supportsOAuthAccount(connection) ||
    connectors.some(item => item.plugin_id === connection.plugin_id && item.personal_credentials)
  )
}
