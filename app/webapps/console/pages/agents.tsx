import { recordValue } from '@pleisto/active-support'
import { Badge, Input, Separator, TableCell, TableRow, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useParams } from 'react-router'
import {
  ankoleWebAgentControllerCreateMutation,
  ankoleWebAgentControllerDeleteMutation,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentControllerIndexModelProfilesOptions,
  ankoleWebAgentControllerUpdateMutation,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebCodexAccountControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { blankToNull, formatJSON, parseObjectDraft } from '../console-primitives'
import { JSONField, LabeledField, ResourceEditorPage, ResourceListPage, RowActions } from '../console-shell'
import { AgentEditorModel, type AgentEditorDraft } from '../state/agent-editor-model'
import { ModelProfilesEditor } from './model-profiles-editor'
import { WorkerEnvAgentSection } from './worker-env-agent-section'

export function AgentsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const rows = agents.data?.agents ?? []
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
      emptyTitle={t('console.agents.empty_title')}
      emptyDescription={t('console.agents.empty_description')}
      error={agents.error}>
      {rows.map(agent => (
        <TableRow key={agent.uid} className="cursor-pointer" onClick={() => navigate(encodeURIComponent(agent.uid))}>
          <TableCell className="font-mono text-xs">{agent.uid}</TableCell>
          <TableCell>{agent.role}</TableCell>
          <TableCell>
            <Badge variant={agent.status === 'active' ? 'default' : 'secondary'}>{agent.status}</Badge>
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
  const codexAccounts = useQuery(ankoleWebCodexAccountControllerIndexOptions())
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
      navigate(`../${encodeURIComponent(response.agent.uid)}`)
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
    const parsed = parseObjectDraft(model.options.value, 'options')
    if (!parsed.ok) {
      model.validationError.value = parsed.error
      return
    }
    const body = {
      display_name: blankToNull(model.displayName.value),
      avatar_url: blankToNull(model.avatarURL.value),
      role: model.role.value.trim(),
      options: parsed.value
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
      backTo=".."
      error={model.validationError.value ?? createAgent.error ?? updateAgent.error}
      submitting={createAgent.isPending || updateAgent.isPending}
      onSubmit={submit}>
      <LabeledField
        label={t('console.agents.uid')}
        description={t('console.agents.uid_hint')}
        required={mode === 'new'}>
        <Input
          disabled={mode === 'edit'}
          placeholder="research-analyst"
          value={model.uid.value}
          onChange={event => (model.uid.value = event.target.value)}
        />
      </LabeledField>
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.agents.display_name')}>
          <Input value={model.displayName.value} onChange={event => (model.displayName.value = event.target.value)} />
        </LabeledField>
        <LabeledField label={t('console.agents.role')}>
          <Input value={model.role.value} onChange={event => (model.role.value = event.target.value)} />
        </LabeledField>
      </div>
      <LabeledField label={t('console.agents.avatar_url')}>
        <Input value={model.avatarURL.value} onChange={event => (model.avatarURL.value = event.target.value)} />
      </LabeledField>
      <JSONField
        label={t('console.agents.options')}
        description={t('console.agents.options_hint')}
        value={model.options.value}
        onChange={value => (model.options.value = value)}
      />

      {mode === 'edit' && selectedAgent ? (
        <>
          <Separator />
          <ModelProfilesEditor
            agent={selectedAgent}
            error={modelProfiles.error}
            loading={modelProfiles.isLoading}
            profiles={recordValue(modelProfiles.data?.model_profiles) ?? {}}
            providers={providers.data?.ai_gateway_providers ?? []}
            codexAccounts={codexAccounts.data?.codex_accounts ?? []}
            onChanged={refresh}
          />
          <Separator />
          <WorkerEnvAgentSection agentUID={selectedAgent.uid} />
        </>
      ) : null}
    </ResourceEditorPage>
  )
}

function emptyAgentForm(): AgentEditorDraft {
  return {
    uid: '',
    displayName: '',
    avatarURL: '',
    role: 'Research Analyst',
    options: '{}'
  }
}

function formFromAgent(agent: AgentItem): AgentEditorDraft {
  return {
    uid: agent.uid,
    displayName: agent.display_name ?? '',
    avatarURL: agent.avatar_url ?? '',
    role: agent.role,
    options: formatJSON(agent.options)
  }
}
