import { recordValue } from '@pleisto/active-support'
import { Badge, Input, Separator, TableCell, TableRow, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useParams } from 'react-router'
import {
  ankoleWebAgentControllerCreateMutation,
  ankoleWebAgentControllerDeleteMutation,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentControllerUpdateMutation,
  ankoleWebAiGatewayProviderControllerIndexModelProfilesOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { blankToNull, formatJson, parseObjectDraft } from '../console-primitives'
import { JsonField, LabeledField, ResourceEditorPage, ResourceListPage, RowActions } from '../console-shell'
import { ModelProfilesEditor } from './model-profiles-editor'

export function AgentsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const rows = agents.data?.data ?? []
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

type AgentForm = {
  uid: string
  displayName: string
  avatarUrl: string
  role: string
  options: string
}

export function AgentEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const uid = params.uid ? decodeURIComponent(params.uid) : undefined
  const mode = uid ? 'edit' : 'new'

  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const providers = useQuery(ankoleWebAiGatewayProviderControllerIndexOptions())
  const selectedAgent = agents.data?.data.find(agent => agent.uid === uid)
  const modelProfiles = useQuery({
    ...ankoleWebAiGatewayProviderControllerIndexModelProfilesOptions({ path: { agent_uid: selectedAgent?.uid ?? '' } }),
    enabled: Boolean(selectedAgent?.uid)
  })

  const [form, setForm] = useState<AgentForm>(emptyAgentForm())
  const [error, setError] = useState<string>()
  const refresh = () => void queryClient.invalidateQueries()

  useEffect(() => {
    setForm(mode === 'edit' && selectedAgent ? formFromAgent(selectedAgent) : emptyAgentForm())
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, selectedAgent?.uid])

  const createAgent = useMutation({
    ...ankoleWebAgentControllerCreateMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.saved', { id: response.data.uid }))
      refresh()
      // Land on the new agent's editor so model profiles can be configured next.
      navigate(`../${encodeURIComponent(response.data.uid)}`)
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })
  const updateAgent = useMutation({
    ...ankoleWebAgentControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.agents.saved', { id: response.data.uid }))
      refresh()
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })

  const submit = () => {
    setError(undefined)
    const parsed = parseObjectDraft(form.options, 'options')
    if (!parsed.ok) {
      setError(parsed.error)
      return
    }
    const body = {
      display_name: blankToNull(form.displayName),
      avatar_url: blankToNull(form.avatarUrl),
      role: form.role.trim(),
      options: parsed.value
    }
    if (mode === 'new') {
      createAgent.mutate({ body: { ...body, uid: form.uid.trim() } })
      return
    }
    if (selectedAgent) updateAgent.mutate({ body, path: { agent_uid: selectedAgent.uid } })
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.agents.new') : (uid ?? '')}
      description={t('console.agents.editor_description')}
      backTo=".."
      error={error ?? createAgent.error ?? updateAgent.error}
      submitting={createAgent.isPending || updateAgent.isPending}
      onSubmit={submit}>
      <LabeledField
        label={t('console.agents.uid')}
        description={t('console.agents.uid_hint')}
        required={mode === 'new'}>
        <Input
          disabled={mode === 'edit'}
          placeholder="research-analyst"
          value={form.uid}
          onChange={event => setForm(current => ({ ...current, uid: event.target.value }))}
        />
      </LabeledField>
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.agents.display_name')}>
          <Input
            value={form.displayName}
            onChange={event => setForm(current => ({ ...current, displayName: event.target.value }))}
          />
        </LabeledField>
        <LabeledField label={t('console.agents.role')}>
          <Input value={form.role} onChange={event => setForm(current => ({ ...current, role: event.target.value }))} />
        </LabeledField>
      </div>
      <LabeledField label={t('console.agents.avatar_url')}>
        <Input
          value={form.avatarUrl}
          onChange={event => setForm(current => ({ ...current, avatarUrl: event.target.value }))}
        />
      </LabeledField>
      <JsonField
        label={t('console.agents.options')}
        description={t('console.agents.options_hint')}
        value={form.options}
        onChange={value => setForm(current => ({ ...current, options: value }))}
      />

      {mode === 'edit' && selectedAgent ? (
        <>
          <Separator />
          <ModelProfilesEditor
            agent={selectedAgent}
            error={modelProfiles.error}
            loading={modelProfiles.isLoading}
            profiles={recordValue(modelProfiles.data?.data) ?? {}}
            providers={providers.data?.data ?? []}
            onChanged={refresh}
          />
        </>
      ) : null}
    </ResourceEditorPage>
  )
}

function emptyAgentForm(): AgentForm {
  return {
    uid: '',
    displayName: '',
    avatarUrl: '',
    role: 'Research Analyst',
    options: '{}'
  }
}

function formFromAgent(agent: AgentItem): AgentForm {
  return {
    uid: agent.uid,
    displayName: agent.display_name ?? '',
    avatarUrl: agent.avatar_url ?? '',
    role: agent.role,
    options: formatJson(agent.options)
  }
}
