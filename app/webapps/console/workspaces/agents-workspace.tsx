import { recordValue } from '@pleisto/active-support'
import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Input,
  Separator,
  TableCell,
  TableRow,
  Textarea
} from '@ankole/uikit'
import { RiAddLine, RiDeleteBin6Line, RiSave3Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAgentControllerCreateMutation,
  ankoleWebAgentControllerDeleteMutation,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentControllerUpdateMutation,
  ankoleWebAiGatewayProviderControllerIndexModelProfilesOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/generated/types.gen'
import {
  ErrorBlock,
  Field,
  ResourceTable,
  WorkspaceShell,
  blankToNull,
  formatJson,
  parseObjectDraft,
  useSelectFirst
} from '../console-primitives'
import { ModelProfilesEditor } from './model-profiles-editor'

type AgentDraft = {
  uid: string
  displayName: string
  avatarUrl: string
  role: string
  options: string
  error?: string
}

export function AgentsWorkspace() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const providers = useQuery(ankoleWebAiGatewayProviderControllerIndexOptions())
  const [mode, setMode] = useState<'new' | 'edit'>('new')
  const [selectedUid, setSelectedUid] = useSelectFirst(agents.data?.data, agent => agent.uid, () => setMode('edit'))
  const selectedAgent = agents.data?.data.find(agent => agent.uid === selectedUid)
  const modelProfiles = useQuery({
    ...ankoleWebAiGatewayProviderControllerIndexModelProfilesOptions({
      path: { agent_uid: selectedAgent?.uid ?? '' }
    }),
    enabled: Boolean(selectedAgent?.uid)
  })
  const [draft, setDraft] = useState<AgentDraft>(emptyAgentDraft())

  const refresh = () => void queryClient.invalidateQueries()
  const createAgent = useMutation({ ...ankoleWebAgentControllerCreateMutation(), onSuccess: refresh })
  const updateAgent = useMutation({ ...ankoleWebAgentControllerUpdateMutation(), onSuccess: refresh })
  const deleteAgent = useMutation({
    ...ankoleWebAgentControllerDeleteMutation(),
    onSuccess: () => {
      setMode('new')
      setSelectedUid(null)
      refresh()
    }
  })

  useEffect(() => {
    setDraft(mode === 'edit' && selectedAgent ? draftFromAgent(selectedAgent) : emptyAgentDraft())
  }, [mode, selectedAgent?.uid])

  const saveAgent = () => {
    const parsed = parseObjectDraft(draft.options, 'options')
    if (!parsed.ok) {
      setDraft(current => ({ ...current, error: parsed.error }))
      return
    }

    const body = {
      display_name: blankToNull(draft.displayName),
      avatar_url: blankToNull(draft.avatarUrl),
      role: draft.role.trim(),
      options: parsed.value
    }

    if (mode === 'new') {
      createAgent.mutate({
        body: {
          ...body,
          uid: draft.uid.trim()
        }
      })
      return
    }

    if (selectedAgent) {
      updateAgent.mutate({
        body,
        path: { agent_uid: selectedAgent.uid }
      })
    }
  }

  return (
    <WorkspaceShell
      title={t('console.agents.title')}
      action={
        <Button
          size="sm"
          type="button"
          variant="outline"
          onClick={() => {
            setMode('new')
            setSelectedUid(null)
          }}>
          <RiAddLine data-icon="inline-start" />
          {t('common.new')}
        </Button>
      }>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <ErrorBlock error={agents.error} />
          <ResourceTable
            columns={[t('console.agents.uid'), t('console.agents.role'), t('console.agents.status')]}
            empty={!agents.isLoading && (agents.data?.data.length ?? 0) === 0}
            loading={agents.isLoading}>
            {agents.data?.data.map(agent => (
              <TableRow
                key={agent.uid}
                data-state={agent.uid === selectedAgent?.uid ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => {
                  setMode('edit')
                  setSelectedUid(agent.uid)
                }}>
                <TableCell className="font-mono text-xs">{agent.uid}</TableCell>
                <TableCell>{agent.role}</TableCell>
                <TableCell>
                  <Badge variant={agent.status === 'active' ? 'default' : 'secondary'}>{agent.status}</Badge>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>

        <Card size="sm" className="min-w-0">
          <CardHeader>
            <div className="flex items-start justify-between gap-3">
              <CardTitle>{mode === 'new' ? t('console.agents.new') : selectedAgent?.uid}</CardTitle>
              {mode === 'edit' && selectedAgent ? (
                <Button
                  aria-label={t('console.aria.disable_agent')}
                  disabled={deleteAgent.isPending}
                  size="icon-sm"
                  type="button"
                  variant="outline"
                  onClick={() => deleteAgent.mutate({ path: { agent_uid: selectedAgent.uid } })}>
                  <RiDeleteBin6Line />
                </Button>
              ) : null}
            </div>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? createAgent.error ?? updateAgent.error ?? deleteAgent.error} />
            <Field label={t('console.agents.uid')}>
              <Input
                disabled={mode === 'edit'}
                value={draft.uid}
                onChange={event => setDraft(current => ({ ...current, uid: event.target.value }))}
              />
            </Field>
            <div className="grid gap-4 md:grid-cols-2">
              <Field label={t('console.agents.display_name')}>
                <Input
                  value={draft.displayName}
                  onChange={event => setDraft(current => ({ ...current, displayName: event.target.value }))}
                />
              </Field>
              <Field label={t('console.agents.role')}>
                <Input
                  value={draft.role}
                  onChange={event => setDraft(current => ({ ...current, role: event.target.value }))}
                />
              </Field>
            </div>
            <Field label={t('console.agents.avatar_url')}>
              <Input
                value={draft.avatarUrl}
                onChange={event => setDraft(current => ({ ...current, avatarUrl: event.target.value }))}
              />
            </Field>
            <Field label={t('console.agents.options')}>
              <Textarea
                className="min-h-40 font-mono text-xs"
                spellCheck={false}
                value={draft.options}
                onChange={event => setDraft(current => ({ ...current, options: event.target.value }))}
              />
            </Field>
            <div className="flex flex-wrap gap-2">
              <Button
                disabled={createAgent.isPending || updateAgent.isPending}
                size="sm"
                type="button"
                onClick={saveAgent}>
                <RiSave3Line data-icon="inline-start" />
                {t('common.save')}
              </Button>
            </div>
            {selectedAgent ? (
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
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function emptyAgentDraft(): AgentDraft {
  return {
    uid: '',
    displayName: '',
    avatarUrl: '',
    role: 'Research Analyst',
    options: '{}'
  }
}

function draftFromAgent(agent: AgentItem): AgentDraft {
  return {
    uid: agent.uid,
    displayName: agent.display_name ?? '',
    avatarUrl: agent.avatar_url ?? '',
    role: agent.role,
    options: formatJson(agent.options)
  }
}
