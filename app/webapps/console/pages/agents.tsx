import { recordValue } from '@pleisto/active-support'
import { Input, TableCell, TableRow, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAgentControllerCreateMutation,
  ankoleWebAgentControllerDeleteMutation,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentControllerIndexModelProfilesOptions,
  ankoleWebAgentControllerUpdateMutation,
  ankoleWebAiGatewayControllerModelsOptions as ankoleWebAIGatewayControllerModelsOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions as ankoleWebAIGatewayProviderControllerProviderKindsOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { blankToNull } from '../console-primitives'
import { LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { AgentEditorModel, type AgentEditorDraft } from '../state/agent-editor-model'
import { matchesResourceSearch } from '../state/resource-search'
import { AgentLibraryEditor } from './agent-library-editor'
import { ModelProfilesEditor } from './model-profiles-editor'
import { WorkerEnvAgentSection } from './worker-env-agent-section'

export function AgentsListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const rows = (agents.data?.agents ?? []).filter(agent =>
    matchesResourceSearch(deferredQuery, agent.uid, agent.display_name, agent.role, agent.status)
  )
  const deleteAgent = useMutation({
    ...ankoleWebAgentControllerDeleteMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.agents.deleted', { id: variables.path.agent_uid }))
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
      columns={[t('console.agents.uid'), t('console.agents.role'), t('console.agents.status')]}
      isLoading={agents.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.agents.empty_title')}
      emptyDescription={t('console.agents.empty_description')}
      error={agents.error}
      isFiltered={Boolean(query.trim())}
      toolbar={
        <ResourceSearch
          label={t('console.agents.search')}
          placeholder={t('console.agents.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(agent => (
        <TableRow key={agent.uid}>
          <TableCell className="font-mono text-xs">
            <Link className="text-foreground hover:text-link hover:underline" to={encodeURIComponent(agent.uid)}>
              {agent.uid}
            </Link>
          </TableCell>
          <TableCell>{agent.role}</TableCell>
          <TableCell>
            <StatusIndicator tone={agent.status === 'active' ? 'positive' : 'neutral'}>
              {t(`console.status.${agent.status}`)}
            </StatusIndicator>
          </TableCell>
          <RowActions
            editTo={encodeURIComponent(agent.uid)}
            editLabel={t('common.edit')}
            deletePending={deleteAgent.isPending}
            deleteConfirm={{
              title: t('console.agents.delete_title'),
              description: t('console.agents.delete_description', { id: agent.uid }),
              confirmLabel: t('common.disable')
            }}
            onDelete={() => deleteAgent.mutate({ path: { agent_uid: agent.uid } })}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function AgentEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(AgentEditorModel)
  const params = useParams()
  const uid = params.uid ? decodeURIComponent(params.uid) : undefined
  const mode = uid ? 'edit' : 'new'

  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const providers = useQuery(ankoleWebAIGatewayProviderControllerIndexOptions())
  const providerKinds = useQuery({
    ...ankoleWebAIGatewayProviderControllerProviderKindsOptions(),
    enabled: Boolean(uid)
  })
  const modelCatalog = useQuery({
    ...ankoleWebAIGatewayControllerModelsOptions(),
    enabled: Boolean(uid)
  })
  const selectedAgent = agents.data?.agents.find(agent => agent.uid === uid)
  const modelProfiles = useQuery({
    ...ankoleWebAgentControllerIndexModelProfilesOptions({ path: { agent_uid: selectedAgent?.uid ?? '' } }),
    enabled: Boolean(selectedAgent?.uid)
  })

  const refresh = () => void queryClient.invalidateQueries()

  useEffect(() => {
    if (mode === 'new') model.initialize('new', emptyAgentForm())
    else if (selectedAgent) model.initialize(`agent:${selectedAgent.uid}`, formFromAgent(selectedAgent))
  }, [mode, model, selectedAgent])

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
      refresh()
    }
  })

  const submit = () => {
    model.clearValidation()
    const body = {
      display_name: blankToNull(model.displayName.value),
      avatar_url: blankToNull(model.avatarURL.value),
      role: model.role.value.trim()
    }
    if (mode === 'new') {
      createAgent.mutate({ body: { ...body, uid: model.uid.value.trim() } })
      return
    }
    if (selectedAgent) updateAgent.mutate({ body, path: { agent_uid: selectedAgent.uid } })
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.agents.new') : (uid ?? '')}
      description={t('console.agents.editor_description')}
      backTo="/agents"
      error={model.validationError.value ?? createAgent.error ?? updateAgent.error}
      submitting={createAgent.isPending || updateAgent.isPending}
      submitLabel={mode === 'edit' ? t('console.agents.save_identity') : t('common.save')}
      supplementary={
        mode === 'edit' && selectedAgent ? (
          <div className="grid gap-10 border-t border-border pt-8">
            <AgentLibraryEditor agentUID={selectedAgent.uid} />
            <ModelProfilesEditor
              agent={selectedAgent}
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
      <LabeledField
        label={t('console.agents.uid')}
        description={t('console.agents.uid_hint')}
        required={mode === 'new'}>
        {mode === 'edit' ? (
          <ReadOnlyValue mono>{model.uid.value}</ReadOnlyValue>
        ) : (
          <Input
            placeholder="research-analyst"
            value={model.uid.value}
            onChange={event => (model.uid.value = event.target.value)}
          />
        )}
      </LabeledField>
      {/* Display name and role are not a natural pair like a city and a postcode,
          and a two-column row of unrelated fields is the layout most often
          misread. One column, in the order the fields are filled. */}
      <LabeledField label={t('console.agents.display_name')}>
        <Input value={model.displayName.value} onChange={event => (model.displayName.value = event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.agents.role')}>
        <Input value={model.role.value} onChange={event => (model.role.value = event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.agents.avatar_url')}>
        <Input value={model.avatarURL.value} onChange={event => (model.avatarURL.value = event.target.value)} />
      </LabeledField>
    </ResourceEditorPage>
  )
}

function emptyAgentForm(): AgentEditorDraft {
  return {
    uid: '',
    displayName: '',
    avatarURL: '',
    role: 'Research Analyst'
  }
}

function formFromAgent(agent: AgentItem): AgentEditorDraft {
  return {
    uid: agent.uid,
    displayName: agent.display_name ?? '',
    avatarURL: agent.avatar_url ?? '',
    role: agent.role
  }
}
