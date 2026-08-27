import { match, recordValue } from '@agentbull/active-support'
import {
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  cn,
  toast
} from '@ankole/uikit'
import { RiPauseCircleLine, RiPlayCircleLine, RiRobot2Line } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAgentControllerCreateMutation,
  ankoleWebAgentControllerDeleteMutation,
  ankoleWebAgentControllerEnableMutation,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentControllerIndexModelProfilesOptions,
  ankoleWebAgentControllerShowOptions,
  ankoleWebAgentControllerUpdateMutation,
  ankoleWebAiGatewayControllerModelsOptions as ankoleWebAIGatewayControllerModelsOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions as ankoleWebAIGatewayProviderControllerProviderKindsOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { ErrorBlock } from '../../common/error-block'
import { blankToNull } from '../console-primitives'
import { LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { BackLink, PageStack } from '../console-page'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { SinglePrincipalPicker } from '../principal-picker'
import {
  agentUIDError,
  AgentEditorModel,
  type AgentEditorDraft,
  type AgentMemoryDisclosureMode
} from '../state/agent-editor-model'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { AgentLibraryEditor } from './agent-library-editor'
import { CustomModelProfilesEditor } from './custom-model-profiles-editor'
import { ModelProfilesEditor } from './model-profiles-editor'
import { WorkerEnvAgentSection } from './worker-env-agent-section'

export function AgentsListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (agents.data?.agents ?? []).filter(agent =>
    matchesResourceSearch(searchQuery, agent.uid, agent.display_name, agent.role, agent.status)
  )
  // The DELETE response reports status "disabled" for both steps, so the
  // toast keys on the row's status at click time: a disabled row's delete is
  // the permanent one.
  const deleteAgent = useMutation({
    ...ankoleWebAgentControllerDeleteMutation(),
    onSuccess: () => void queryClient.invalidateQueries(),
    onError: error => toast.error(requestErrorMessage(error))
  })
  const enableAgent = useMutation({
    ...ankoleWebAgentControllerEnableMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.agents.enabled', { id: variables.path.agent_uid }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.agents.title')}
      description={t('console.agents.description')}
      createTo="new"
      createLabel={t('console.agents.new')}
      columns={[
        t('console.agents.uid'),
        t('console.agents.display_name'),
        t('console.agents.role'),
        t('console.agents.status')
      ]}
      isLoading={agents.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.agents.empty_title')}
      emptyDescription={t('console.agents.empty_description')}
      emptyIcon={<RiRobot2Line aria-hidden />}
      error={agents.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.agents.search')}
          placeholder={t('console.agents.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(agent => {
        const disabled = agent.status === 'disabled'
        return (
          <TableRow key={agent.uid}>
            <TableCell className="font-mono text-xs">
              <Link className="text-foreground hover:text-link hover:underline" to={encodeURIComponent(agent.uid)}>
                {agent.uid}
              </Link>
            </TableCell>
            <TableCell className={agent.display_name ? undefined : 'text-muted-foreground'}>
              {agent.display_name || '—'}
            </TableCell>
            <TableCell>{agent.role}</TableCell>
            <TableCell>
              <StatusIndicator tone={disabled ? 'neutral' : 'positive'}>
                {t(`console.status.${agent.status}`)}
              </StatusIndicator>
            </TableCell>
            <RowActions
              editTo={encodeURIComponent(agent.uid)}
              editLabel={t('common.edit')}
              actions={
                disabled
                  ? [
                      {
                        icon: <RiPlayCircleLine />,
                        label: t('common.enable'),
                        pending: enableAgent.isPending,
                        onAction: () => enableAgent.mutate({ path: { agent_uid: agent.uid } })
                      }
                    ]
                  : []
              }
              deletePending={deleteAgent.isPending}
              deleteConfirm={
                disabled
                  ? {
                      title: t('console.agents.delete_title'),
                      description: t('console.agents.delete_description', { id: agent.uid }),
                      confirmLabel: t('common.delete')
                    }
                  : {
                      title: t('console.agents.disable_title'),
                      description: t('console.agents.disable_description', { id: agent.uid }),
                      confirmLabel: t('common.disable'),
                      icon: <RiPauseCircleLine />
                    }
              }
              onDelete={() =>
                deleteAgent.mutate(
                  { path: { agent_uid: agent.uid } },
                  {
                    onSuccess: () =>
                      toast.success(
                        t(disabled ? 'console.agents.deleted' : 'console.agents.disabled_toast', {
                          id: agent.uid
                        })
                      )
                  }
                )
              }
            />
          </TableRow>
        )
      })}
    </ResourceListPage>
  )
}

export function agentEditorDetailOptions(uid: string) {
  return {
    ...ankoleWebAgentControllerShowOptions({ path: { agent_uid: uid } }),
    enabled: Boolean(uid),
    refetchOnMount: 'always' as const
  }
}

export function AgentEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(AgentEditorModel)
  const displayNameInput = useRef<HTMLInputElement>(null)
  const uidInput = useRef<HTMLInputElement>(null)
  const roleInput = useRef<HTMLInputElement>(null)
  const params = useParams()
  const uid = params.uid
  const mode = uid ? 'edit' : 'new'
  const [touched, setTouched] = useState({ displayName: false, role: false, uid: false })

  const agentDetail = useQuery(agentEditorDetailOptions(uid ?? ''))
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const providers = useQuery(ankoleWebAIGatewayProviderControllerIndexOptions())
  const providerKinds = useQuery({
    ...ankoleWebAIGatewayProviderControllerProviderKindsOptions(),
    enabled: Boolean(uid)
  })
  const modelCatalog = useQuery({
    ...ankoleWebAIGatewayControllerModelsOptions(),
    enabled: Boolean(uid)
  })
  const selectedAgent = agentDetail.data?.agent
  const modelProfiles = useQuery({
    ...ankoleWebAgentControllerIndexModelProfilesOptions({ path: { agent_uid: selectedAgent?.uid ?? '' } }),
    enabled: Boolean(selectedAgent?.uid)
  })

  const refresh = () => void queryClient.invalidateQueries()

  useEffect(() => {
    if (mode === 'new') model.initialize('new', emptyAgentForm())
    else if (selectedAgent) model.initialize(`agent:${selectedAgent.uid}`, formFromAgent(selectedAgent))
  }, [mode, model, selectedAgent])

  // Touched flags belong to the route's agent, not to query identity: a
  // background refetch must not clear blur-driven validation errors while the
  // operator is still on the same editor.
  useEffect(() => {
    setTouched({ displayName: false, role: false, uid: false })
  }, [uid])

  const createAgent = useMutation({
    ...ankoleWebAgentControllerCreateMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.saved', { id: response.agent.uid }))
      refresh()
      // Land on the new agent's editor so model profiles can be configured next.
      navigate(`/agents/${encodeURIComponent(response.agent.uid)}`)
    }
  })
  const updateAgent = useMutation({
    ...ankoleWebAgentControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.saved', { id: response.agent.uid }))
      model.markSaved(formFromAgent(response.agent))
      refresh()
    }
  })

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError(mode)
    if (draftError) {
      model.validationError.value = draftError
      match(draftError)
        .with('display_name_required', () => displayNameInput.current?.focus())
        .with('uid_required', 'uid_invalid', () => uidInput.current?.focus())
        .with('role_required', () => roleInput.current?.focus())
        // The owner picker renders no focusable ref; its inline error is the signal.
        .with('owner_required', () => undefined)
        .exhaustive()
      return
    }
    const body = {
      display_name: model.displayName.value.trim(),
      avatar_url: blankToNull(model.avatarURL.value),
      role: model.role.value.trim(),
      owner_principal_uid: model.ownerPrincipalUID.value.trim(),
      group_memory_disclosure_mode: model.groupMemoryDisclosureMode.value
    }
    if (mode === 'new') {
      createAgent.mutate({ body: { ...body, uid: model.uid.value.trim() } })
      return
    }
    if (selectedAgent) updateAgent.mutate({ body, path: { agent_uid: selectedAgent.uid } })
  }

  const validationMessage = model.validationError.value ? t(`console.agents.${model.validationError.value}`) : undefined
  const displayNameError =
    model.validationError.value === 'display_name_required' || (touched.displayName && !model.displayName.value.trim())
      ? (validationMessage ?? t('console.agents.display_name_required'))
      : undefined
  const uidDraftError = mode === 'new' ? agentUIDError(model.uid.value) : undefined
  const uidError =
    model.validationError.value === 'uid_required' || model.validationError.value === 'uid_invalid'
      ? validationMessage
      : touched.uid && uidDraftError
        ? t(`console.agents.${uidDraftError}`)
        : undefined
  const roleError =
    model.validationError.value === 'role_required' || (touched.role && !model.role.value.trim())
      ? (validationMessage ?? t('console.agents.role_required'))
      : undefined
  const ownerError = model.validationError.value === 'owner_required' ? validationMessage : undefined
  const submitDisabledReason =
    mode === 'edit' && !model.dirty.value ? t('console.agents.save_disabled_unchanged') : undefined

  // The detail endpoint owns absence; disabled agents stay editable so an
  // operator can inspect them before re-enabling or deleting.
  const agentUnavailable = agentDetail.error?.error?.code === 'not_found'
  if (mode === 'edit' && agentUnavailable) {
    return (
      <PageStack className="mx-auto w-full max-w-3xl">
        <BackLink to="/agents" />
        <ErrorBlock
          title={t('console.not_found.title')}
          error={new Error(t('console.agents.not_found', { uid: uid ?? '' }))}
        />
      </PageStack>
    )
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.agents.new') : (uid ?? '')}
      description={t('console.agents.editor_description')}
      backTo="/agents"
      error={
        createAgent.error ??
        updateAgent.error ??
        agentDetail.error ??
        providers.error ??
        providerKinds.error ??
        modelCatalog.error
      }
      submitting={createAgent.isPending || updateAgent.isPending}
      submitDisabled={mode === 'edit' && !model.dirty.value}
      submitUnavailable={mode === 'edit' && !selectedAgent}
      submitDisabledReason={submitDisabledReason}
      submitLabel={mode === 'edit' ? t('console.agents.save_identity') : t('common.save')}
      contentWidth={mode === 'edit' ? 'wide' : 'form'}
      supplementary={
        mode === 'edit' && selectedAgent ? (
          <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-10 border-t border-border pt-8 [&>*]:min-w-0">
            {/* The key remounts the editor per agent, so tab choice, draft
                model, and in-flight submission bookkeeping reset structurally. */}
            <AgentLibraryEditor key={selectedAgent.uid} agentUID={selectedAgent.uid} />
            <ModelProfilesEditor
              agent={selectedAgent}
              error={modelProfiles.error}
              loading={modelProfiles.isLoading}
              profiles={recordValue(modelProfiles.data?.model_profiles) ?? {}}
              providerHosted={modelProfiles.data?.provider_hosted ?? { web_search: true, image_generate: true }}
              providers={providers.data?.ai_gateway_providers ?? []}
              providerKinds={providerKinds.data?.provider_kinds ?? []}
              modelCatalog={modelCatalog.data}
              onChanged={refresh}
            />
            <CustomModelProfilesEditor
              agentUID={selectedAgent.uid}
              error={modelProfiles.error}
              loading={modelProfiles.isLoading}
              profiles={recordValue(modelProfiles.data?.model_profiles) ?? {}}
              providers={providers.data?.ai_gateway_providers ?? []}
              providerKinds={providerKinds.data?.provider_kinds ?? []}
              modelCatalog={modelCatalog.data}
              onChanged={refresh}
            />
            <WorkerEnvAgentSection agentUID={selectedAgent.uid} />
          </div>
        ) : null
      }
      onSubmit={submit}>
      <div className={cn('grid gap-5', mode === 'edit' && 'md:grid-cols-2')}>
        <LabeledField label={t('console.agents.display_name')} error={displayNameError} required>
          <Input
            aria-invalid={displayNameError ? true : undefined}
            aria-required="true"
            required
            ref={displayNameInput}
            value={model.displayName.value}
            onBlur={() => setTouched(current => ({ ...current, displayName: true }))}
            onChange={event => model.setDisplayName(event.target.value, mode === 'new')}
          />
        </LabeledField>
        <LabeledField
          label={t('console.agents.uid')}
          description={t('console.agents.uid_hint')}
          error={uidError}
          required={mode === 'new'}>
          {mode === 'edit' ? (
            <ReadOnlyValue mono>{model.uid.value}</ReadOnlyValue>
          ) : (
            <Input
              aria-invalid={uidError ? true : undefined}
              aria-required="true"
              required
              autoCapitalize="none"
              autoComplete="off"
              maxLength={96}
              ref={uidInput}
              spellCheck={false}
              value={model.uid.value}
              onBlur={() => setTouched(current => ({ ...current, uid: true }))}
              onChange={event => model.setUID(event.target.value)}
            />
          )}
        </LabeledField>
        <LabeledField
          label={t('console.agents.role')}
          description={t('console.agents.role_hint')}
          error={roleError}
          required>
          <Input
            aria-invalid={roleError ? true : undefined}
            aria-required="true"
            required
            ref={roleInput}
            value={model.role.value}
            onBlur={() => setTouched(current => ({ ...current, role: true }))}
            onChange={event => {
              model.role.value = event.target.value
              if (model.validationError.value === 'role_required') model.clearValidation()
            }}
          />
        </LabeledField>
        <LabeledField label={t('console.agents.avatar_url')}>
          <Input value={model.avatarURL.value} onChange={event => (model.avatarURL.value = event.target.value)} />
        </LabeledField>
        <LabeledField
          label={t('console.agents.owner')}
          description={t('console.agents.owner_hint')}
          error={ownerError}
          required>
          <SinglePrincipalPicker
            ariaLabel={t('console.agents.owner')}
            error={principals.error}
            isLoading={principals.isLoading}
            placeholder={t('console.agents.owner_placeholder')}
            candidates={(principals.data?.principals ?? []).map(principal => ({
              id: principal.uid,
              label: principal.display_name
            }))}
            value={model.ownerPrincipalUID.value}
            onChange={ownerUID => {
              model.ownerPrincipalUID.value = ownerUID
              if (model.validationError.value === 'owner_required') model.clearValidation()
            }}
          />
        </LabeledField>
        <LabeledField
          label={t('console.agents.group_memory_disclosure_mode')}
          description={t('console.agents.group_memory_disclosure_mode_hint')}>
          <Select
            value={model.groupMemoryDisclosureMode.value}
            onValueChange={value => {
              if (value === 'strict' || value === 'relaxed') {
                model.groupMemoryDisclosureMode.value = value satisfies AgentMemoryDisclosureMode
              }
            }}>
            <SelectTrigger aria-label={t('console.agents.group_memory_disclosure_mode')} className="w-full">
              <SelectValue>{value => t(`console.agents.group_memory_disclosure_mode_${String(value)}`)}</SelectValue>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="strict">{t('console.agents.group_memory_disclosure_mode_strict')}</SelectItem>
              <SelectItem value="relaxed">{t('console.agents.group_memory_disclosure_mode_relaxed')}</SelectItem>
            </SelectContent>
          </Select>
        </LabeledField>
      </div>
    </ResourceEditorPage>
  )
}

function emptyAgentForm(): AgentEditorDraft {
  return {
    uid: '',
    displayName: '',
    avatarURL: '',
    role: '',
    ownerPrincipalUID: '',
    groupMemoryDisclosureMode: 'strict'
  }
}

function formFromAgent(agent: AgentItem): AgentEditorDraft {
  return {
    uid: agent.uid,
    displayName: agent.display_name ?? '',
    avatarURL: agent.avatar_url ?? '',
    role: agent.role,
    ownerPrincipalUID: agent.owner_principal_uid,
    groupMemoryDisclosureMode: agent.group_memory_disclosure_mode
  }
}
