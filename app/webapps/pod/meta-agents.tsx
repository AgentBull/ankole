import {
  Avatar,
  AvatarImage,
  AvatarFallback,
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'
import { useSignal } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ContentError, ContentSkeleton } from './content-primitives'
import { refreshAgentQueries } from './query-cache'
import { MarkdownBody } from '../common/markdown-body'
import { MetaDocument } from './meta-document'
import {
  metaKeys,
  metaAgentsQuery,
  ensurePodPersonalAssistant,
  metaAgentQuery,
  metaContractsQuery,
  metaCreateAgent,
  metaUpdateAgent,
  metaSaveAgentContract,
  metaSaveGlobalContract,
  type MetaAgent
} from './meta-api'

export function MetaAgents() {
  const { t } = useTranslation()
  const agents = useQuery(metaAgentsQuery())
  const [creating, setCreating] = useState(false)
  return (
    <div className="mx-auto w-full max-w-4xl space-y-5 p-6">
      <div className="flex items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">{t('pod.meta.agents')}</h1>
        {agents.data?.can_create && <Button onClick={() => setCreating(!creating)}>{t('pod.meta.new_agent')}</Button>}
      </div>
      {creating && <AgentIdentity />}
      {agents.error && <ContentError error={agents.error} retry={() => void agents.refetch()} />}
      <ul className="divide-y divide-border rounded-lg border border-border">
        {agents.data?.agents
          .filter(agent => agent.type === 'ai_colleague')
          .map(agent => (
            <li key={agent.uid}>
              <Link to={`/meta/agents/colleagues/${agent.uid}`} className="nav-row flex items-center gap-3 p-4">
                <AgentAvatar agent={agent} />
                <span className="min-w-0">
                  <span className="block font-medium">{agent.display_name}</span>
                  <span className="block text-sm text-fg-secondary">{agent.role}</span>
                </span>
              </Link>
            </li>
          ))}
        <li>
          <Link to="/meta/agents/assistant" className="nav-row flex p-4">
            {t('pod.meta.assistant')}
          </Link>
        </li>
        <li>
          <Link to="/meta/agents/global" className="nav-row flex p-4">
            {t('pod.meta.global')}
          </Link>
        </li>
      </ul>
    </div>
  )
}
function AgentAvatar({ agent }: { agent: MetaAgent }) {
  return (
    <Avatar>
      <AvatarImage src={agent.avatar_url ?? undefined} alt="" />
      <AvatarFallback>{agent.display_name.slice(0, 1)}</AvatarFallback>
    </Avatar>
  )
}

function AgentIdentity({ agent }: { agent?: MetaAgent }) {
  useSignals()
  const { t } = useTranslation()
  const id = useId()
  const client = useQueryClient()
  const navigate = useNavigate()
  const form = useSignal({
    uid: agent?.uid ?? '',
    display_name: agent?.display_name ?? '',
    role: agent?.role ?? '',
    avatar_url: agent?.avatar_url ?? ''
  })
  const mutation = useMutation({
    mutationFn: () =>
      agent
        ? metaUpdateAgent({
            path: { uid: agent.uid },
            body: { data: { display_name: form.value.display_name, avatar_url: form.value.avatar_url || null } }
          })
        : metaCreateAgent({ body: { data: form.value } }),
    onSuccess: async result => {
      await refreshAgentQueries(client)
      if (!agent) void navigate({ to: `/meta/agents/colleagues/${result.uid}` })
    }
  })
  if (agent && !agent.can_edit) {
    return (
      <section className="space-y-3 rounded-lg border border-border p-5">
        <AgentAvatar agent={agent} />
        <h2 className="font-semibold">{t('pod.meta.identity')}</h2>
        <dl className="grid grid-cols-[auto_1fr] gap-x-5 gap-y-2 text-sm">
          <dt>{t('pod.meta.display_name')}</dt>
          <dd>{agent.display_name}</dd>
          <dt>{t('pod.meta.uid')}</dt>
          <dd>{agent.uid}</dd>
          <dt>{t('pod.meta.role')}</dt>
          <dd>{agent.role}</dd>
        </dl>
      </section>
    )
  }
  return (
    <form
      className="space-y-3 rounded-lg border border-border p-5"
      onSubmit={event => {
        event.preventDefault()
        mutation.mutate()
      }}>
      <h2 className="font-semibold">{t('pod.meta.identity')}</h2>
      {agent && <AgentAvatar agent={{ ...agent, avatar_url: form.value.avatar_url }} />}
      {(agent ? (['display_name', 'avatar_url'] as const) : (['uid', 'display_name', 'role'] as const)).map(field => (
        <div key={field}>
          <label htmlFor={`${id}-${field}`} className="mb-1 block text-sm">
            {t(`pod.meta.${field}`)}
          </label>
          <Input
            id={`${id}-${field}`}
            required={field !== 'avatar_url'}
            value={form.value[field]}
            disabled={mutation.isPending || (agent && !agent.can_edit)}
            onChange={event => {
              form.value = { ...form.value, [field]: event.target.value }
              mutation.reset()
            }}
          />
        </div>
      ))}
      {(!agent || agent.can_edit) && (
        <Button type="submit" disabled={mutation.isPending}>
          {t(agent ? 'common.save' : 'pod.meta.create')}
        </Button>
      )}
      {mutation.error && <ContentError error={mutation.error} />}
      {mutation.isSuccess && (
        <p role="status" className="text-sm text-fg-secondary">
          {t('pod.meta.saved')}
        </p>
      )}
    </form>
  )
}
export function MetaAgentDetail() {
  const { uid } = useParams({ from: '/meta/agents/colleagues/$uid' })
  return <AgentSettings uid={uid} />
}

export function MetaAssistant() {
  const { t } = useTranslation()
  const agents = useQuery(metaAgentsQuery())
  const client = useQueryClient()
  const create = useMutation({
    mutationFn: () => ensurePodPersonalAssistant(),
    onSuccess: () => client.invalidateQueries({ queryKey: metaKeys.agents() })
  })
  const assistant = agents.data?.agents.find(agent => agent.type === 'personal_assistant')
  if (agents.error) return <ContentError error={agents.error} retry={() => void agents.refetch()} />
  if (!agents.data) return <ContentSkeleton variant="page" />
  if (assistant) return <AgentSettings uid={assistant.uid} title={t('pod.meta.assistant')} />
  return (
    <div className="mx-auto max-w-4xl space-y-4 p-6">
      <h1 className="text-2xl font-semibold">{t('pod.meta.assistant')}</h1>
      <p>{t('pod.meta.assistant_not_created')}</p>
      <Button disabled={create.isPending} onClick={() => create.mutate()}>
        {t('pod.meta.create_assistant')}
      </Button>
      {create.error && <ContentError error={create.error} />}
    </div>
  )
}

export function MetaGlobalSettings() {
  const { t } = useTranslation()
  return (
    <div className="mx-auto w-full max-w-4xl space-y-5 p-6">
      <h1 className="text-2xl font-semibold">{t('pod.meta.global')}</h1>
      <Contracts uid={null} />
    </div>
  )
}

function AgentSettings({ uid, title }: { uid: string; title?: string }) {
  const agent = useQuery(metaAgentQuery(uid))
  return (
    <div className="mx-auto w-full max-w-4xl space-y-5 p-6">
      <h1 className="text-2xl font-semibold">{title ?? agent.data?.display_name}</h1>
      {agent.error && <ContentError error={agent.error} retry={() => void agent.refetch()} />}
      {agent.data && <AgentIdentity key={agent.data.uid} agent={agent.data} />}
      <Contracts uid={uid} />
    </div>
  )
}

function Contracts({ uid }: { uid: string | null }) {
  const contracts = useQuery(metaContractsQuery(uid))
  return (
    <>
      {contracts.error && <ContentError error={contracts.error} retry={() => void contracts.refetch()} />}
      {contracts.isPending && <ContentSkeleton variant="list" rows={3} />}
      {contracts.data?.contracts.map(contract => (
        <Contract key={`${uid}:${contract.slot}`} uid={uid} contract={contract} canEdit={contracts.data.can_edit} />
      ))}
    </>
  )
}
function Contract({
  uid,
  contract,
  canEdit
}: {
  uid: string | null
  contract: NonNullable<Awaited<ReturnType<typeof import('./meta-api').metaAgentContracts>>>['contracts'][number]
  canEdit: boolean
}) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const mode = useSignal(contract.mode)
  return (
    <>
      <MetaDocument
        title={`${contract.slot.toUpperCase()}.md`}
        xml={contract.content_xml}
        metadata={contract.metadata}
        revision={contract.revision}
        canEdit={canEdit}
        pendingChanges={mode.value !== contract.mode}
        bodyEnabled={editing => (editing ? mode.value : contract.mode) !== 'inherit'}
        onBegin={() => {
          mode.value = contract.mode
        }}
        save={async value => {
          try {
            const slot = contract.slot as 'agents' | 'design'
            const body = {
              data: {
                content_xml: value.xml,
                metadata: value.metadata,
                base_revision: value.base_revision,
                mode: mode.value as 'inherit' | 'append' | 'override'
              }
            }
            return uid === null
              ? await metaSaveGlobalContract({ path: { slot }, body })
              : await metaSaveAgentContract({ path: { uid, slot }, body })
          } finally {
            await client.invalidateQueries({ queryKey: metaKeys.contracts(uid) })
          }
        }}>
        {editing =>
          uid !== null && (
            <div className="space-y-1">
              <label id={`mode-${contract.slot}`} className="block text-sm">
                {t('pod.meta.contract_mode')}
              </label>
              <Select
                value={editing ? mode.value : contract.mode}
                onValueChange={value => {
                  mode.value = String(value)
                }}
                disabled={!canEdit || !editing}>
                <SelectTrigger aria-labelledby={`mode-${contract.slot}`}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {['inherit', 'append', 'override'].map(value => (
                    <SelectItem key={value} value={value}>
                      {t(`pod.meta.mode_${value}`)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <p className="text-xs text-fg-secondary">{t('pod.meta.contract_save_hint')}</p>
              {(editing ? mode.value : contract.mode) === 'inherit' && (
                <p className="text-sm text-fg-secondary">{t('pod.meta.inherited_hint')}</p>
              )}
            </div>
          )
        }
      </MetaDocument>
      {uid !== null && (
        <details className="rounded-lg border border-border p-5">
          <summary className="cursor-pointer text-sm font-medium">
            {t('pod.meta.effective_contract', { slot: `${contract.slot.toUpperCase()}.md` })}
          </summary>
          <div className="mt-4">
            <MarkdownBody text={contract.effective_markdown} />
          </div>
        </details>
      )}
    </>
  )
}
