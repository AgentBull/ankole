import { principalLabel } from '../state/principal-label'
import { ActorLabel } from '../actor-label'
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
import { useMutation, useQuery } from '@tanstack/react-query'
import { useDeferredValue, useMemo, useRef, useState } from 'react'
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
  ankoleWebAiGatewayProviderControllerModelsOptions as ankoleWebAIGatewayControllerModelsOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions as ankoleWebAIGatewayProviderControllerProviderKindsOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/generated/types.gen'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { blankToNull } from '../console-primitives'
import { EditorNotFound, LabeledField, ResourceEditorPage, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { SinglePrincipalPicker } from '../principal-picker'
import {
  agentHandleInputPattern,
  AgentEditorModel,
  type AgentEditorDraft,
  type AgentMemoryDisclosureMode
} from '../state/agent-editor-model'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { useEditorDraft } from '../use-editor-draft'
import { AgentLibraryEditor } from './agent-library-editor'
import { AgentLibraryEditorModel } from '../state/agent-library-editor-model'
import { CustomModelProfilesEditor } from './custom-model-profiles-editor'
import { ModelProfilesEditor } from './model-profiles-editor'
import { TokenQuotaEditor } from './token-quota-editor'
import { WorkerEnvAgentSection } from './worker-env-agent-section'
import { AgentFilesLink } from './agent-files'
import { AgentWorkerProvider, WorkerProviderSelect } from './agent-worker-provider'
import { ankoleWebWorkerProviderControllerIndexOptions } from '../api/generated/@tanstack/react-query.gen'

export function AgentsListPage() {
  const { t } = useTranslation()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (agents.data?.agents ?? []).filter(agent =>
    matchesResourceSearch(searchQuery, agent.handle, agent.uid, agent.display_name, agent.role, agent.status)
  )
  // The DELETE response reports status "disabled" for both steps, so the
  // toast keys on the row's status at click time: a disabled row's delete is
  // the permanent one.
  const deleteAgent = useMutation({
    ...ankoleWebAgentControllerDeleteMutation(),
    onError: error => toast.error(requestErrorMessage(error))
  })
  const enableAgent = useMutation({
    ...ankoleWebAgentControllerEnableMutation(),
    onSuccess: data => {
      toast.success(t('console.agents.enabled', { id: data.agent.handle }))
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
        t('console.agents.handle'),
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
              <Link data-row-link className="text-foreground" to={encodeURIComponent(agent.uid)}>
                {agent.handle}
              </Link>
            </TableCell>
            <TableCell>{agent.display_name}</TableCell>
            <TableCell>{agent.role}</TableCell>
            <TableCell>
              <StatusIndicator tone={disabled ? 'neutral' : 'positive'}>
                {t(`console.status.${agent.status}`)}
              </StatusIndicator>
            </TableCell>
            <RowActions
              // The confirmed action changes from disable to delete with the
              // row status. A new action surface must not inherit a closing
              // dialog from the prior status.
              key={`${agent.uid}:${agent.status}`}
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
                      description: t('console.agents.delete_description', { id: agent.handle }),
                      confirmLabel: t('common.delete')
                    }
                  : {
                      title: t('console.agents.disable_title'),
                      description: t('console.agents.disable_description', { id: agent.handle }),
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
                          id: agent.handle
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
  const { uid } = useParams()
  return <AgentEditor key={uid ?? 'new'} uid={uid} />
}

function AgentEditor({ uid }: { uid?: string }) {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(AgentEditorModel)
  const libraryModel = useModel(AgentLibraryEditorModel)
  const displayNameInput = useRef<HTMLInputElement>(null)
  const handleInput = useRef<HTMLInputElement>(null)
  const roleInput = useRef<HTMLInputElement>(null)
  const mode = uid ? 'edit' : 'new'

  const agentDetail = useQuery(agentEditorDetailOptions(uid ?? ''))
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const owners = (principals.data?.principals ?? []).filter(principal => principal.type === 'human')
  const needsOwner = mode === 'new' && principals.isSuccess && owners.length === 0
  const providers = useQuery(ankoleWebAIGatewayProviderControllerIndexOptions())
  const workerProviders = useQuery(ankoleWebWorkerProviderControllerIndexOptions())
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
  const agentDraft = useMemo(
    () =>
      mode === 'new'
        ? workerProviders.data
          ? emptyAgentForm(
              workerProviders.data.worker_providers.find(provider => provider.is_default)?.provider_id ?? ''
            )
          : undefined
        : selectedAgent
          ? formFromAgent(selectedAgent)
          : undefined,
    [mode, selectedAgent, workerProviders.data]
  )
  const draftStatus = useEditorDraft(model, {
    identity: { resource: 'agent', uid },
    source: agentDraft,
    absent: () => mode === 'edit' && requestErrorCode(agentDetail.error) === 'not_found'
  })

  const createAgent = useMutation({
    ...ankoleWebAgentControllerCreateMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.saved', { id: response.agent.handle }))

      // Land on the new agent's editor so model profiles can be configured next.
      navigate(`/agents/${encodeURIComponent(response.agent.uid)}`)
    }
  })
  const updateAgent = useMutation({
    ...ankoleWebAgentControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.saved', { id: response.agent.handle }))
      model.markSaved(formFromAgent(response.agent))
    }
  })

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError(mode)
    if (draftError) {
      model.validationError.value = draftError
      match(draftError)
        .with('display_name_required', () => displayNameInput.current?.focus())
        .with('handle_required', 'handle_invalid', () => handleInput.current?.focus())
        .with('role_required', () => roleInput.current?.focus())
        // The owner picker renders no focusable ref; its inline error is the signal.
        .with('owner_required', 'worker_provider_required', () => undefined)
        .exhaustive()
      return
    }
    const body = {
      handle: model.handle.value.trim(),
      display_name: model.displayName.value.trim(),
      avatar_url: blankToNull(model.avatarURL.value),
      role: model.role.value.trim(),
      owner_principal_uid: model.ownerPrincipalUID.value.trim(),
      group_memory_disclosure_mode: model.groupMemoryDisclosureMode.value
    }
    if (mode === 'new') {
      createAgent.mutate({
        body: { ...body, worker_provider_id: model.workerProviderID.value }
      })
      return
    }
    if (selectedAgent) updateAgent.mutate({ body, path: { agent_uid: selectedAgent.uid } })
  }

  // Blur-time required and pattern feedback comes from LabeledField; these
  // carry only the submit-time decisions of the draft model, which also
  // covers values the model derives without a keystroke, such as the handle.
  // Required messages reuse the shared template, so the text never changes
  // between blur and submit.
  const draftError = model.validationError.value
  const requiredText = (labelKey: string) => t('common.field_required', { field: t(labelKey) })
  const displayNameError =
    draftError === 'display_name_required' ? requiredText('console.agents.display_name') : undefined
  const handleError =
    draftError === 'handle_required'
      ? requiredText('console.agents.handle')
      : draftError === 'handle_invalid'
        ? t('console.agents.handle_invalid')
        : undefined
  const roleError = draftError === 'role_required' ? requiredText('console.agents.role') : undefined
  const ownerError = draftError === 'owner_required' ? requiredText('console.agents.owner') : undefined
  const submitDisabledReason =
    mode === 'edit' && !model.dirty.value ? t('console.agents.save_disabled_unchanged') : undefined

  // The detail endpoint owns absence; disabled agents stay editable so an
  // operator can inspect them before re-enabling or deleting.
  if (draftStatus === 'absent') {
    return <EditorNotFound backTo="/agents" message={t('console.agents.not_found', { uid: uid ?? '' })} />
  }

  return (
    <ResourceEditorPage
      title={
        mode === 'new' ? t('console.agents.new') : selectedAgent?.display_name || selectedAgent?.handle || (uid ?? '')
      }
      description={t('console.agents.editor_description')}
      backTo="/agents"
      dirty={model.dirty.value}
      supplementaryDirty={libraryModel.dirty.value}
      error={
        createAgent.error ??
        updateAgent.error ??
        agentDetail.error ??
        workerProviders.error ??
        providers.error ??
        providerKinds.error ??
        modelCatalog.error
      }
      submitting={createAgent.isPending || updateAgent.isPending}
      submitDisabled={mode === 'edit' && !model.dirty.value}
      submitUnavailable={draftStatus !== 'ready' || needsOwner}
      submitDisabledReason={submitDisabledReason}
      submitLabel={mode === 'edit' ? t('console.agents.save_identity') : t('common.save')}
      contentWidth={mode === 'edit' ? 'wide' : 'form'}
      supplementary={
        mode === 'edit' && selectedAgent ? (
          <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-10 border-t border-border pt-8 [&>*]:min-w-0">
            <AgentWorkerProvider agent={selectedAgent} providers={workerProviders.data?.worker_providers ?? []} />
            <AgentLibraryEditor agentUID={selectedAgent.uid} model={libraryModel} />
            <ModelProfilesEditor
              agent={selectedAgent}
              error={modelProfiles.error}
              loading={modelProfiles.isLoading}
              profiles={recordValue(modelProfiles.data?.model_profiles) ?? {}}
              providerHosted={modelProfiles.data?.provider_hosted ?? { web_search: true, image_generate: true }}
              providers={providers.data?.ai_gateway_providers ?? []}
              providerKinds={providerKinds.data?.provider_kinds ?? []}
              modelCatalog={modelCatalog.data?.models ?? []}
            />
            <CustomModelProfilesEditor
              agentUID={selectedAgent.uid}
              error={modelProfiles.error}
              loading={modelProfiles.isLoading}
              profiles={recordValue(modelProfiles.data?.model_profiles) ?? {}}
              providers={providers.data?.ai_gateway_providers ?? []}
              providerKinds={providerKinds.data?.provider_kinds ?? []}
              modelCatalog={modelCatalog.data?.models ?? []}
            />
            <TokenQuotaEditor key={selectedAgent.uid} agentUID={selectedAgent.uid} />
            <WorkerEnvAgentSection agentUID={selectedAgent.uid} />
            <AgentFilesLink agentUID={selectedAgent.uid} />
          </div>
        ) : null
      }
      onSubmit={submit}>
      <div className={cn('grid gap-5', mode === 'edit' && 'md:grid-cols-2')}>
        {mode === 'new' ? (
          <LabeledField
            label={t('console.worker_providers.provider')}
            description={t('console.worker_providers.agent_hint')}
            required
            error={
              draftError === 'worker_provider_required' ? requiredText('console.worker_providers.provider') : undefined
            }>
            <WorkerProviderSelect
              providers={workerProviders.data?.worker_providers ?? []}
              value={model.workerProviderID.value}
              onChange={value => {
                model.workerProviderID.value = value
                model.clearValidation()
              }}
            />
          </LabeledField>
        ) : null}
        <LabeledField label={t('console.agents.display_name')} error={displayNameError} required>
          <Input
            aria-invalid={displayNameError ? true : undefined}
            aria-required="true"
            required
            ref={displayNameInput}
            value={model.displayName.value}
            onChange={event => model.setDisplayName(event.target.value, mode === 'new')}
          />
        </LabeledField>
        <LabeledField
          label={t('console.agents.handle')}
          description={t('console.agents.handle_hint')}
          error={handleError}
          invalidError={t('console.agents.handle_invalid')}
          required>
          <Input
            aria-invalid={handleError ? true : undefined}
            aria-required="true"
            required
            autoCapitalize="none"
            autoComplete="off"
            maxLength={96}
            pattern={agentHandleInputPattern}
            ref={handleInput}
            spellCheck={false}
            value={model.handle.value}
            onChange={event => model.setHandle(event.target.value)}
          />
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
          description={t(needsOwner ? 'console.agents.owner_empty' : 'console.agents.owner_hint')}
          error={ownerError}
          required>
          <SinglePrincipalPicker
            ariaLabel={t('console.agents.owner')}
            error={principals.error}
            isLoading={principals.isLoading}
            placeholder={t('console.agents.owner_placeholder')}
            candidates={owners.map(principal => ({
              id: principal.uid,
              label: principalLabel(principal),
              description: principal.email ?? principal.handle
            }))}
            value={model.ownerPrincipalUID.value}
            onChange={ownerUID => {
              model.ownerPrincipalUID.value = ownerUID
              if (model.validationError.value === 'owner_required') model.clearValidation()
            }}
          />
        </LabeledField>
        {needsOwner ? (
          <Link className="text-sm underline" to="/access/principals">
            {t('console.principals.title')}
          </Link>
        ) : null}
        {selectedAgent?.created_by ? (
          <LabeledField label={t('console.agents.created_by')}>
            <ActorLabel actor={selectedAgent.created_by} />
          </LabeledField>
        ) : null}
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
              <SelectValue />
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

function emptyAgentForm(workerProviderID: string): AgentEditorDraft {
  return {
    handle: '',
    displayName: '',
    avatarURL: '',
    role: '',
    ownerPrincipalUID: '',
    workerProviderID,
    groupMemoryDisclosureMode: 'strict'
  }
}

function formFromAgent(agent: AgentItem): AgentEditorDraft {
  return {
    handle: agent.handle,
    displayName: agent.display_name,
    avatarURL: agent.avatar_url ?? '',
    role: agent.role,
    ownerPrincipalUID: agent.owner_principal_uid,
    workerProviderID: agent.worker_provider_id ?? '',
    groupMemoryDisclosureMode: agent.group_memory_disclosure_mode
  }
}
