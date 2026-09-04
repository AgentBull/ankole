import {
  Badge,
  Button,
  Checkbox,
  Combobox,
  ComboboxChip,
  ComboboxChips,
  ComboboxChipsInput,
  ComboboxCollection,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxItem,
  ComboboxList,
  ComboboxValue,
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
  TableCell,
  TableRow,
  Textarea,
  toast,
  useComboboxAnchor
} from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine, RiKey2Line, RiRefreshLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAuthZGroupControllerIndexOptions,
  ankoleWebAiGatewayControllerModelsOptions as ankoleWebAIGatewayControllerModelsOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions as ankoleWebAIGatewayProviderControllerProviderKindsOptions,
  ankoleWebOidcClientControllerCreateMutation,
  ankoleWebOidcClientControllerDeleteMutation,
  ankoleWebOidcClientControllerIndexOptions,
  ankoleWebOidcClientControllerRotateSecretMutation,
  ankoleWebOidcClientControllerShowOptions,
  ankoleWebOidcClientControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem,
  ModelProfileWriteRequest,
  OidcClientCreateRequest,
  OidcClientItem,
  OidcClientUpdateRequest,
  PrincipalGroupItem
} from '../api/generated/types.gen'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { ConfirmDeleteButton, EditorNotFound, LabeledField, ReadOnlyValue, ResourceEditorPage } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { principalGroupDescription, principalGroupDisplayName } from '../state/principal-group-text'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { emptyProfileDraft, type ProfileDraft } from '../state/model-profiles-model'
import { customProfileNameError } from './custom-model-profiles-editor'
import { ModelProfileEditorCard, buildModelProfileWriteRequest } from './model-profile-editor-card'

const supportedScopes = ['openid', 'profile', 'email', 'offline_access', 'ai_gateway.write'] as const
type OidcScope = (typeof supportedScopes)[number]

type ClientDraft = {
  allowedGroupIDs: string[]
  modelAliases: ClientModelAliasDraft[]
  enabled: boolean
  name: string
  redirectURIs: string
  scopes: OidcScope[]
  type: 'public' | 'confidential'
}

type ClientModelAliasDraft = {
  key: string
  name: string
  persisted: boolean
  profile: ProfileDraft
  nameError?: string
  savedProfileKey?: string
}

type SecretState = { nextPath?: string; value: string }

export function OIDCClientsListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const clients = useQuery(ankoleWebOidcClientControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (clients.data?.oidc_clients ?? []).filter(client =>
    matchesResourceSearch(
      searchQuery,
      client.name,
      client.id,
      client.type,
      client.enabled ? 'enabled' : 'disabled',
      ...client.scopes,
      ...client.redirect_uris
    )
  )
  const remove = useMutation({
    ...ankoleWebOidcClientControllerDeleteMutation(),
    onSuccess: (_response, variables) => {
      const client = clients.data?.oidc_clients.find(item => item.id === variables.path.id)
      toast.success(t('console.oidc_clients.deleted', { name: client?.name ?? variables.path.id }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.oidc_clients.title')}
      description={t('console.oidc_clients.description')}
      createTo="new"
      createLabel={t('console.oidc_clients.new')}
      columns={[
        t('console.oidc_clients.name'),
        t('console.oidc_clients.client_id'),
        t('console.oidc_clients.type'),
        t('console.oidc_clients.scopes'),
        t('console.oidc_clients.state')
      ]}
      isLoading={clients.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.oidc_clients.empty_title')}
      emptyIcon={<RiKey2Line aria-hidden />}
      emptyDescription={t('console.oidc_clients.empty_description')}
      error={clients.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.oidc_clients.search')}
          placeholder={t('console.oidc_clients.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(client => (
        <TableRow key={client.id}>
          <TableCell>
            <Link
              className="font-medium text-foreground hover:text-link hover:underline"
              to={encodeURIComponent(client.id)}>
              {client.name}
            </Link>
          </TableCell>
          <TableCell className="max-w-72 font-mono text-xs break-all whitespace-normal">{client.id}</TableCell>
          <TableCell>
            <Badge variant="secondary">{t(`console.oidc_clients.type_${client.type}`)}</Badge>
          </TableCell>
          <TableCell>
            <div className="flex max-w-80 flex-wrap gap-1.5">
              {client.scopes.map(scope => (
                <Badge key={scope} variant={scope === 'ai_gateway.write' ? 'info' : 'outline'}>
                  {scope}
                </Badge>
              ))}
            </div>
          </TableCell>
          <TableCell>
            <Badge variant={client.enabled ? 'success' : 'outline'}>
              {t(client.enabled ? 'console.status.enabled' : 'console.status.disabled')}
            </Badge>
          </TableCell>
          <RowActions
            editTo={encodeURIComponent(client.id)}
            editLabel={t('common.edit')}
            deletePending={remove.isPending}
            deleteConfirm={{
              title: t('console.oidc_clients.delete_title'),
              description: t('console.oidc_clients.delete_description', { name: client.name }),
              confirmLabel: t('common.delete')
            }}
            onDelete={() => remove.mutate({ path: { id: client.id } })}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function OIDCClientEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { clientID } = useParams()
  const mode = clientID ? 'edit' : 'new'
  const [draft, setDraft] = useState<ClientDraft>(emptyDraft)
  const [savedDraft, setSavedDraft] = useState(() => draftKey(emptyDraft()))
  const [validationError, setValidationError] = useState<string>()
  const [secret, setSecret] = useState<SecretState>()
  const initializedFor = useRef<string | undefined>(undefined)
  const nextAliasID = useRef(0)
  const aiGatewayEnabled = draft.scopes.includes('ai_gateway.write')

  const clientQuery = useQuery({
    ...ankoleWebOidcClientControllerShowOptions({ path: { id: clientID ?? '' } }),
    enabled: Boolean(clientID)
  })
  const groups = useQuery(ankoleWebAuthZGroupControllerIndexOptions())
  const providers = useQuery({
    ...ankoleWebAIGatewayProviderControllerIndexOptions(),
    enabled: aiGatewayEnabled
  })
  const providerKinds = useQuery({
    ...ankoleWebAIGatewayProviderControllerProviderKindsOptions(),
    enabled: aiGatewayEnabled
  })
  const modelCatalog = useQuery({
    ...ankoleWebAIGatewayControllerModelsOptions(),
    enabled: aiGatewayEnabled
  })
  const loadedClient = clientQuery.data?.oidc_client

  useEffect(() => {
    const resourceKey = clientID ? `client:${clientID}` : 'new'
    if (initializedFor.current === resourceKey) return

    if (mode === 'new') {
      const next = emptyDraft()
      setDraft(next)
      setSavedDraft(draftKey(next))
      initializedFor.current = resourceKey
    } else if (loadedClient) {
      const next = draftFromClient(loadedClient)
      setDraft(next)
      setSavedDraft(draftKey(next))
      initializedFor.current = resourceKey
    }
  }, [clientID, loadedClient, mode])

  const dirty = draftKey(draft) !== savedDraft
  const refresh = () => void queryClient.invalidateQueries()

  const createClient = useMutation({
    ...ankoleWebOidcClientControllerCreateMutation(),
    onSuccess: response => {
      const next = draftFromClient(response.oidc_client)
      setDraft(next)
      setSavedDraft(draftKey(next))
      refresh()
      toast.success(t('console.oidc_clients.saved', { name: response.oidc_client.name }))
      const nextPath = `/oidc-clients/${encodeURIComponent(response.oidc_client.id)}`
      if (response.client_secret) setSecret({ nextPath, value: response.client_secret })
      else navigate(nextPath)
    }
  })
  const updateClient = useMutation({
    ...ankoleWebOidcClientControllerUpdateMutation(),
    onSuccess: response => {
      const next = draftFromClient(response.oidc_client)
      setDraft(next)
      setSavedDraft(draftKey(next))
      refresh()
      toast.success(t('console.oidc_clients.saved', { name: response.oidc_client.name }))
    }
  })
  const rotateSecret = useMutation({
    ...ankoleWebOidcClientControllerRotateSecretMutation(),
    onSuccess: response => {
      refresh()
      if (response.client_secret) setSecret({ value: response.client_secret })
      toast.success(t('console.oidc_clients.secret_rotated'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeClient = useMutation({
    ...ankoleWebOidcClientControllerDeleteMutation(),
    onSuccess: response => {
      refresh()
      toast.success(t('console.oidc_clients.deleted', { name: response.oidc_client.name }))
      navigate('/oidc-clients')
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const submit = () => {
    setValidationError(undefined)

    if (aiGatewayEnabled && draft.allowedGroupIDs.length === 0) {
      setValidationError(t('console.oidc_clients.group_required'))
      return
    }
    if (aiGatewayEnabled && draft.modelAliases.length === 0) {
      setValidationError(t('console.oidc_clients.model_required'))
      return
    }

    const builtAliases = aiGatewayEnabled
      ? buildModelAliases(
          draft.modelAliases,
          providers.data?.ai_gateway_providers ?? [],
          providerKinds.data?.provider_kinds ?? [],
          t
        )
      : ({ ok: true, value: {} } as const)

    if (!builtAliases.ok) {
      setDraft(current => ({
        ...current,
        modelAliases: current.modelAliases.map(alias => ({
          ...alias,
          nameError:
            alias.key === builtAliases.aliasKey && builtAliases.field === 'name' ? builtAliases.error : undefined,
          profile: {
            ...alias.profile,
            error:
              alias.key === builtAliases.aliasKey && builtAliases.field === 'profile' ? builtAliases.error : undefined
          }
        }))
      }))
      setValidationError(builtAliases.error)
      return
    }

    const body = writeBody(draft, builtAliases.value)

    if (mode === 'new') {
      createClient.mutate({ body: { ...body, type: draft.type } })
    } else if (clientID) {
      updateClient.mutate({ body, path: { id: clientID } })
    }
  }

  const setScope = (scope: OidcScope, checked: boolean) => {
    if (scope === 'openid') return
    const scopes = checked ? [...draft.scopes, scope] : draft.scopes.filter(value => value !== scope)
    setDraft({
      ...draft,
      allowedGroupIDs: scope === 'ai_gateway.write' && !checked ? [] : draft.allowedGroupIDs,
      modelAliases: scope === 'ai_gateway.write' && !checked ? [] : draft.modelAliases,
      scopes: supportedScopes.filter(value => scopes.includes(value))
    })
    setValidationError(undefined)
  }

  const addModelAlias = () => {
    const key = `new:${nextAliasID.current}`
    nextAliasID.current += 1
    setDraft(current => ({
      ...current,
      modelAliases: [...current.modelAliases, { key, name: '', persisted: false, profile: emptyProfileDraft() }]
    }))
    setValidationError(undefined)
  }

  const updateModelAlias = (key: string, update: (alias: ClientModelAliasDraft) => ClientModelAliasDraft) => {
    setDraft(current => ({
      ...current,
      modelAliases: current.modelAliases.map(alias => (alias.key === key ? update(alias) : alias))
    }))
    setValidationError(undefined)
  }

  const removeModelAlias = (key: string) => {
    setDraft(current => ({
      ...current,
      modelAliases: current.modelAliases.filter(alias => alias.key !== key)
    }))
    setValidationError(undefined)
  }

  const clientNotFound = mode === 'edit' && requestErrorCode(clientQuery.error) === 'not_found'
  if (clientNotFound) {
    return <EditorNotFound backTo="/oidc-clients" message={t('console.oidc_clients.not_found')} />
  }

  const pending = createClient.isPending || updateClient.isPending
  const mutationError = createClient.error ?? updateClient.error

  return (
    <>
      <ResourceEditorPage
        title={mode === 'new' ? t('console.oidc_clients.new') : (loadedClient?.name ?? clientID ?? '')}
        description={t('console.oidc_clients.editor_description')}
        backTo="/oidc-clients"
        dirty={dirty}
        validationError={validationError}
        error={
          mutationError ??
          clientQuery.error ??
          groups.error ??
          (aiGatewayEnabled ? (providers.error ?? providerKinds.error ?? modelCatalog.error) : undefined)
        }
        submitting={pending}
        submitDisabled={mode === 'edit' && !dirty}
        submitUnavailable={
          (mode === 'edit' && !loadedClient) ||
          (aiGatewayEnabled && (providers.isLoading || providerKinds.isLoading || modelCatalog.isLoading))
        }
        contentWidth="wide"
        onSubmit={submit}
        secondary={
          loadedClient ? (
            <div className="flex flex-wrap gap-2">
              {loadedClient.type === 'confidential' ? (
                <Button
                  disabled={rotateSecret.isPending}
                  size="sm"
                  type="button"
                  variant="outline"
                  onClick={() => rotateSecret.mutate({ path: { id: loadedClient.id } })}>
                  <RiRefreshLine data-icon="inline-start" />
                  {t('console.oidc_clients.rotate_secret')}
                </Button>
              ) : null}
              <ConfirmDeleteButton
                label={t('common.delete')}
                pending={removeClient.isPending}
                confirm={{
                  title: t('console.oidc_clients.delete_title'),
                  description: t('console.oidc_clients.delete_description', { name: loadedClient.name }),
                  confirmLabel: t('common.delete')
                }}
                onConfirm={() => removeClient.mutate({ path: { id: loadedClient.id } })}
              />
            </div>
          ) : null
        }>
        {mode === 'edit' ? (
          <LabeledField label={t('console.oidc_clients.client_id')}>
            <ReadOnlyValue mono>{loadedClient?.id}</ReadOnlyValue>
          </LabeledField>
        ) : null}

        <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
          <LabeledField label={t('console.oidc_clients.name')} required>
            <Input required value={draft.name} onChange={event => setDraft({ ...draft, name: event.target.value })} />
          </LabeledField>
          <LabeledField
            label={t('console.oidc_clients.type')}
            description={t('console.oidc_clients.type_hint')}
            required={mode === 'new'}>
            {mode === 'edit' ? (
              <ReadOnlyValue>{t(`console.oidc_clients.type_${draft.type}`)}</ReadOnlyValue>
            ) : (
              <Select
                value={draft.type}
                onValueChange={value => setDraft({ ...draft, type: String(value) as ClientDraft['type'] })}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent emptyLabel={t('common.select_empty')}>
                  <SelectItem value="public">{t('console.oidc_clients.type_public')}</SelectItem>
                  <SelectItem value="confidential">{t('console.oidc_clients.type_confidential')}</SelectItem>
                </SelectContent>
              </Select>
            )}
          </LabeledField>
        </div>

        <label className="flex items-center justify-between gap-4 border border-border bg-muted/30 p-4">
          <span className="grid gap-1">
            <span className="text-sm font-medium">{t('console.oidc_clients.enabled')}</span>
            <span className="text-xs leading-5 text-muted-foreground">{t('console.oidc_clients.enabled_hint')}</span>
          </span>
          <Checkbox
            checked={draft.enabled}
            onCheckedChange={checked => setDraft({ ...draft, enabled: checked === true })}
          />
        </label>

        <LabeledField
          label={t('console.oidc_clients.redirect_uris')}
          description={t('console.oidc_clients.redirect_uris_hint')}
          required>
          <Textarea
            className="min-h-28 font-mono text-xs [resize:vertical]"
            required
            spellCheck={false}
            value={draft.redirectURIs}
            onChange={event => setDraft({ ...draft, redirectURIs: event.target.value })}
          />
        </LabeledField>

        <LabeledField label={t('console.oidc_clients.scopes')} description={t('console.oidc_clients.scopes_hint')}>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            {supportedScopes.map(scope => (
              <label key={scope} className="flex items-start gap-3 border border-border/70 bg-card/60 p-4">
                <Checkbox
                  checked={draft.scopes.includes(scope)}
                  disabled={scope === 'openid'}
                  onCheckedChange={checked => setScope(scope, checked === true)}
                />
                <span className="grid gap-1">
                  <code className="text-xs font-semibold">{scope}</code>
                  <span className="text-xs leading-5 text-muted-foreground">
                    {t(`console.oidc_clients.scope_${scope.replace('.', '_')}`)}
                  </span>
                </span>
              </label>
            ))}
          </div>
        </LabeledField>

        {aiGatewayEnabled ? (
          <>
            <LabeledField
              label={t('console.oidc_clients.allowed_groups')}
              description={t('console.oidc_clients.allowed_groups_hint')}
              error={validationError === t('console.oidc_clients.group_required') ? validationError : undefined}
              required>
              <AllowedGroupsPicker
                ariaLabel={t('console.oidc_clients.allowed_groups')}
                groups={groups.data?.principal_groups ?? []}
                isLoading={groups.isLoading}
                error={groups.error}
                placeholder={t('console.oidc_clients.allowed_groups_placeholder')}
                value={draft.allowedGroupIDs}
                onChange={allowedGroupIDs => {
                  setDraft(current => ({ ...current, allowedGroupIDs }))
                  setValidationError(undefined)
                }}
              />
            </LabeledField>

            <section className="grid gap-4" aria-label={t('console.oidc_clients.allowed_models')}>
              <div className="flex flex-wrap items-start justify-between gap-4">
                <div className="grid gap-1">
                  <h3 className="text-sm font-medium">{t('console.oidc_clients.allowed_models')}</h3>
                  <p className="text-xs leading-5 text-muted-foreground">
                    {t('console.oidc_clients.allowed_models_hint')}
                  </p>
                </div>
                <Button size="sm" type="button" onClick={addModelAlias}>
                  {t('console.oidc_clients.add_model_alias')}
                </Button>
              </div>

              {draft.modelAliases.map(alias => (
                <ModelProfileEditorCard
                  key={alias.key}
                  profile="custom"
                  label={alias.name.trim() || t('console.oidc_clients.new_model_alias')}
                  draft={alias.profile}
                  dirty={!alias.persisted || profileDraftKey(alias.profile) !== alias.savedProfileKey || undefined}
                  required
                  saveIncomplete={Boolean(alias.nameError)}
                  nameField={
                    <LabeledField
                      label={t('console.models.custom_name')}
                      description={t('console.models.custom_name_hint')}
                      error={alias.nameError}
                      required>
                      {alias.persisted ? (
                        <ReadOnlyValue mono>{alias.name}</ReadOnlyValue>
                      ) : (
                        <Input
                          autoFocus
                          maxLength={64}
                          value={alias.name}
                          onChange={event =>
                            updateModelAlias(alias.key, current => ({
                              ...current,
                              name: event.target.value,
                              nameError: undefined,
                              profile: { ...current.profile, error: undefined }
                            }))
                          }
                        />
                      )}
                    </LabeledField>
                  }
                  showDescription
                  persistencePending={pending}
                  deleteConfirm={
                    alias.persisted
                      ? {
                          title: t('console.oidc_clients.delete_model_alias_title'),
                          description: t('console.oidc_clients.delete_model_alias_description', {
                            alias: alias.name
                          }),
                          confirmLabel: t('common.delete')
                        }
                      : undefined
                  }
                  deleteDisabled={false}
                  deleteLabel={t(alias.persisted ? 'common.delete' : 'common.cancel')}
                  providers={providers.data?.ai_gateway_providers ?? []}
                  providerKinds={providerKinds.data?.provider_kinds ?? []}
                  modelCatalog={modelCatalog.data}
                  onUpdate={patch =>
                    updateModelAlias(alias.key, current => ({
                      ...current,
                      profile: { ...current.profile, ...patch }
                    }))
                  }
                  onDelete={() => removeModelAlias(alias.key)}
                />
              ))}

              {draft.modelAliases.length === 0 ? (
                <p className="border border-dashed border-border p-4 text-sm text-muted-foreground">
                  {t('console.oidc_clients.model_aliases_empty')}
                </p>
              ) : null}
            </section>
          </>
        ) : null}
      </ResourceEditorPage>

      <ClientSecretDialog
        secret={secret?.value}
        onClose={() => {
          const nextPath = secret?.nextPath
          setSecret(undefined)
          if (nextPath) navigate(nextPath)
        }}
      />
    </>
  )
}

type GroupOption = {
  description?: string
  id: string
  label: string
  name: string
}

function AllowedGroupsPicker({
  ariaLabel,
  error,
  groups,
  id,
  isLoading,
  onChange,
  placeholder,
  required = false,
  value,
  'aria-describedby': ariaDescribedBy,
  'aria-invalid': ariaInvalid
}: {
  ariaLabel: string
  error: unknown
  groups: PrincipalGroupItem[]
  id?: string
  isLoading: boolean
  onChange: (ids: string[]) => void
  placeholder: string
  required?: boolean
  value: string[]
  'aria-describedby'?: string
  'aria-invalid'?: boolean
}) {
  const { t } = useTranslation()
  const anchor = useComboboxAnchor()
  const [inputValue, setInputValue] = useState('')
  const options = groups.map(group => ({
    id: group.id,
    label: principalGroupDisplayName(t, group),
    name: group.name,
    description: principalGroupDescription(t, group) || undefined
  }))
  const optionsByID = new Map(options.map(option => [option.id, option]))
  const selected = value.map(
    selectedID => optionsByID.get(selectedID) ?? { id: selectedID, label: selectedID, name: selectedID }
  )
  const visible = filterGroupOptions(options, inputValue)

  return (
    <Combobox<GroupOption, true>
      multiple
      filter={null}
      inputValue={inputValue}
      items={visible}
      value={selected}
      isItemEqualToValue={(option, current) => option.id === current.id}
      itemToStringLabel={option => option.label}
      itemToStringValue={option => option.id}
      onInputValueChange={setInputValue}
      onValueChange={next => {
        onChange(next.map(option => option.id))
        setInputValue('')
      }}>
      <ComboboxChips ref={anchor}>
        <ComboboxValue>
          {(selectedOptions: GroupOption[]) =>
            selectedOptions.map(option => (
              <ComboboxChip
                key={option.id}
                removeLabel={t('console.oidc_clients.remove_group', { group: option.label })}>
                {option.label}
              </ComboboxChip>
            ))
          }
        </ComboboxValue>
        <ComboboxChipsInput
          aria-describedby={ariaDescribedBy}
          aria-invalid={ariaInvalid}
          aria-label={ariaLabel}
          aria-required={required || undefined}
          id={id}
          placeholder={placeholder}
          required={required && selected.length === 0}
        />
      </ComboboxChips>
      <ComboboxContent anchor={anchor}>
        <ComboboxList>
          <ComboboxEmpty>
            {error
              ? requestErrorMessage(error)
              : isLoading
                ? t('common.loading')
                : t('console.oidc_clients.allowed_groups_empty')}
          </ComboboxEmpty>
          <ComboboxCollection>
            {(option: GroupOption) => (
              <ComboboxItem key={option.id} value={option}>
                <span className="grid min-w-0 gap-0.5">
                  <span className="truncate">{option.label}</span>
                  <span className="truncate font-mono text-xs text-muted-foreground">{option.name}</span>
                  {option.description ? (
                    <span className="line-clamp-2 text-xs leading-5 text-muted-foreground">{option.description}</span>
                  ) : null}
                </span>
              </ComboboxItem>
            )}
          </ComboboxCollection>
        </ComboboxList>
      </ComboboxContent>
    </Combobox>
  )
}

function ClientSecretDialog({ onClose, secret }: { onClose: () => void; secret?: string }) {
  const { t } = useTranslation()
  const [copied, setCopied] = useState(false)

  useEffect(() => setCopied(false), [secret])

  const copy = async () => {
    if (!secret) return
    try {
      await navigator.clipboard.writeText(secret)
      setCopied(true)
      toast.success(t('console.oidc_clients.secret_copied'))
    } catch {
      toast.error(t('console.oidc_clients.copy_failed'))
    }
  }

  return (
    <Dialog open={Boolean(secret)} onOpenChange={open => !open && onClose()}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.oidc_clients.secret_title')}</DialogTitle>
          <DialogDescription>{t('console.oidc_clients.secret_description')}</DialogDescription>
        </DialogHeader>
        <code className="border border-border bg-muted/30 p-4 font-mono text-sm break-all select-all">{secret}</code>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => void copy()}>
            {copied ? <RiCheckLine data-icon="inline-start" /> : <RiFileCopyLine data-icon="inline-start" />}
            {copied ? t('console.oidc_clients.secret_copied') : t('console.oidc_clients.copy_secret')}
          </Button>
          <Button type="button" onClick={onClose}>
            {t('common.close')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function emptyDraft(): ClientDraft {
  return {
    allowedGroupIDs: [],
    modelAliases: [],
    enabled: true,
    name: '',
    redirectURIs: '',
    scopes: ['openid'],
    type: 'public'
  }
}

function draftFromClient(client: OidcClientItem): ClientDraft {
  return {
    allowedGroupIDs: client.allowed_group_ids,
    modelAliases: Object.entries(client.allowed_models)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([name, profile]) => {
        const draft = profileDraftFromRequest(profile)

        return {
          key: `stored:${name}`,
          name,
          persisted: true,
          profile: draft,
          savedProfileKey: profileDraftKey(draft)
        }
      }),
    enabled: client.enabled,
    name: client.name,
    redirectURIs: client.redirect_uris.join('\n'),
    scopes: supportedScopes.filter(scope => client.scopes.includes(scope)),
    type: client.type
  }
}

function draftKey(draft: ClientDraft): string {
  return JSON.stringify({
    ...draft,
    modelAliases: draft.modelAliases.map(alias => ({
      name: alias.name,
      profile: {
        contextLength: alias.profile.contextLength,
        description: alias.profile.description,
        model: alias.profile.model,
        providerID: alias.profile.providerID,
        providerOptions: alias.profile.providerOptions
      }
    }))
  })
}

function writeBody(
  draft: ClientDraft,
  modelAliases: Record<string, ModelProfileWriteRequest>
): OidcClientUpdateRequest & Omit<OidcClientCreateRequest, 'type'> {
  return {
    allowed_group_ids: draft.allowedGroupIDs,
    allowed_models: modelAliases,
    enabled: draft.enabled,
    name: draft.name.trim(),
    redirect_uris: lines(draft.redirectURIs),
    scopes: draft.scopes
  }
}

function profileDraftFromRequest(profile: ModelProfileWriteRequest): ProfileDraft {
  return {
    contextLength: profile.context_length ? String(profile.context_length) : '',
    description: profile.description ?? '',
    model: profile.model ?? '',
    providerID: profile.provider_id ?? '',
    providerOptions: profile.provider_options ?? {}
  }
}

function profileDraftKey(profile: ProfileDraft): string {
  return JSON.stringify({
    contextLength: profile.contextLength,
    description: profile.description,
    model: profile.model,
    providerID: profile.providerID,
    providerOptions: profile.providerOptions
  })
}

type ModelAliasesBuildResult =
  | { ok: true; value: Record<string, ModelProfileWriteRequest> }
  | { aliasKey: string; error: string; field: 'name' | 'profile'; ok: false }

export function filterGroupOptions(options: GroupOption[], inputValue: string): GroupOption[] {
  const normalized = inputValue.trim().toLowerCase()
  if (!normalized) return options

  return options.filter(option =>
    `${option.label}\n${option.name}\n${option.description ?? ''}`.toLowerCase().includes(normalized)
  )
}

export function buildModelAliases(
  aliases: ClientModelAliasDraft[],
  providers: AIGatewayProviderItem[],
  providerKinds: AIGatewayProviderKindItem[],
  t: ReturnType<typeof useTranslation>['t']
): ModelAliasesBuildResult {
  const names = new Set<string>()
  const value: Record<string, ModelProfileWriteRequest> = {}

  for (const alias of aliases) {
    const name = alias.name.trim()
    const nameError = customProfileNameError(name, names, t)
    if (nameError) return { aliasKey: alias.key, error: nameError, field: 'name', ok: false }
    names.add(name)

    const built = buildModelProfileWriteRequest({
      profile: name,
      draft: alias.profile,
      providers,
      providerKinds,
      t,
      includeDescription: true
    })
    if (!built.ok) return { aliasKey: alias.key, error: built.error, field: 'profile', ok: false }
    value[name] = built.body
  }

  return { ok: true, value }
}

function lines(value: string): string[] {
  return [
    ...new Set(
      value
        .split(/\r?\n/)
        .map(line => line.trim())
        .filter(Boolean)
    )
  ]
}
