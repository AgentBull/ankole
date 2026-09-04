import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider, useQuery } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import type { EditorDraftIdentity, EditorDraftModel } from './use-editor-draft'
import { resolveEditorDraftIdentity, seedEditorDraft, useEditorDraft } from './use-editor-draft'

type DraftCache = { source?: string; absent?: boolean }

const identities: Array<{
  name: string
  identity: EditorDraftIdentity
  sourceKey: string
  initializeKey?: string
}> = [
  { name: 'new agent', identity: { resource: 'agent' }, sourceKey: 'new' },
  { name: 'agent', identity: { resource: 'agent', uid: 'ada' }, sourceKey: 'agent:ada' },
  { name: 'new AI provider', identity: { resource: 'ai-provider' }, sourceKey: 'new' },
  {
    name: 'AI provider',
    identity: { resource: 'ai-provider', providerID: 'openai' },
    sourceKey: 'provider:openai'
  },
  { name: 'new identity provider', identity: { resource: 'identity-provider' }, sourceKey: 'new' },
  {
    name: 'identity provider',
    identity: { resource: 'identity-provider', providerID: 'company' },
    sourceKey: 'provider:company'
  },
  { name: 'new principal', identity: { resource: 'principal' }, sourceKey: 'new' },
  { name: 'principal', identity: { resource: 'principal', uid: 'operator' }, sourceKey: 'principal:operator' },
  { name: 'new principal group', identity: { resource: 'principal-group' }, sourceKey: 'new' },
  {
    name: 'principal group',
    identity: { resource: 'principal-group', name: 'admins' },
    sourceKey: 'group:admins'
  },
  { name: 'new permission grant', identity: { resource: 'permission-grant' }, sourceKey: 'new' },
  {
    name: 'permission grant',
    identity: { resource: 'permission-grant', id: 'grant-1' },
    sourceKey: 'grant:grant-1'
  },
  { name: 'new worker environment variable', identity: { resource: 'worker-env' }, sourceKey: 'worker-env:new' },
  {
    name: 'worker environment variable',
    identity: { resource: 'worker-env', name: 'API_TOKEN' },
    sourceKey: 'worker-env:API_TOKEN'
  },
  { name: 'new schedule', identity: { resource: 'schedule' }, sourceKey: 'cron:new' },
  { name: 'schedule', identity: { resource: 'schedule', id: 'daily' }, sourceKey: 'cron:daily' },
  { name: 'setting', identity: { resource: 'setting', key: 'time.zone' }, sourceKey: 'setting:time.zone' },
  {
    name: 'new signal binding',
    identity: { resource: 'signal-binding', agentUID: 'ada', adapterID: 'slack' },
    sourceKey: 'binding:ada:slack:new'
  },
  {
    name: 'signal binding',
    identity: { resource: 'signal-binding', agentUID: 'ada', adapterID: 'slack', name: 'main' },
    sourceKey: 'binding:ada:slack:main'
  },
  { name: 'new Brain object', identity: { resource: 'brain-object' }, sourceKey: 'new' },
  {
    name: 'Brain object',
    identity: { resource: 'brain-object', slug: 'notes/one' },
    sourceKey: 'object:notes/one'
  },
  {
    name: 'agent library',
    identity: { resource: 'agent-library', agentUID: 'ada' },
    sourceKey: 'agent:ada',
    initializeKey: 'ada'
  },
  {
    name: 'model profiles',
    identity: { resource: 'model-profiles', agentUID: 'ada' },
    sourceKey: 'agent:ada'
  },
  {
    name: 'custom model profile',
    identity: { resource: 'custom-model-profile', agentUID: 'ada', name: 'research' },
    sourceKey: 'agent:ada:research'
  }
]

describe('useEditorDraft', () => {
  test('owns the source keys for every Console draft editor', () => {
    for (const row of identities) {
      const resolved = resolveEditorDraftIdentity(row.identity)
      expect(resolved.sourceKey, row.name).toBe(row.sourceKey)
      expect(resolved.initializeKey, row.name).toBe(row.initializeKey ?? row.sourceKey)
    }
  })

  test('reports every editor ready from manually populated query caches', () => {
    for (const [index, row] of identities.entries()) {
      const queryClient = freshQueryClient()
      const queryKey = ['editor-draft', index] as const
      queryClient.setQueryData<DraftCache>(queryKey, { source: row.name })
      const model = fakeModel(row.sourceKey)

      expect(renderStatus(queryClient, queryKey, model, row.identity), row.name).toContain('>ready<')
    }
  })

  test('distinguishes a pending source from a confirmed absent resource', () => {
    const queryClient = freshQueryClient()
    const queryKey = ['editor-draft', 'lookup'] as const
    const model = fakeModel()
    const identity = { resource: 'agent', uid: 'newly-created' } as const

    queryClient.setQueryData<DraftCache>(queryKey, {})
    expect(renderStatus(queryClient, queryKey, model, identity)).toContain('>loading<')

    queryClient.setQueryData<DraftCache>(queryKey, { absent: true })
    expect(renderStatus(queryClient, queryKey, model, identity)).toContain('>absent<')
  })

  test('does not replace a seeded draft when the same query refetches', () => {
    const model = recordingModel()
    const identity = { resource: 'model-profiles', agentUID: 'ada' } as const

    seedEditorDraft(model, identity, 'cached')
    seedEditorDraft(model, identity, 'refetched')

    expect(model.initializations).toEqual([{ key: 'agent:ada', source: 'cached' }])
  })

  test('seeds a new identity and preserves the agent-library initializer contract', () => {
    const ordinary = recordingModel()
    seedEditorDraft(ordinary, { resource: 'agent', uid: 'ada' }, 'Ada')
    seedEditorDraft(ordinary, { resource: 'agent', uid: 'grace' }, 'Grace')
    expect(ordinary.initializations).toEqual([
      { key: 'agent:ada', source: 'Ada' },
      { key: 'agent:grace', source: 'Grace' }
    ])

    const library = recordingModel(key => `agent:${key}`)
    seedEditorDraft(library, { resource: 'agent-library', agentUID: 'ada' }, 'documents')
    expect(library.initializations).toEqual([{ key: 'ada', source: 'documents' }])
    expect(library.sourceKey.value).toBe('agent:ada')
  })
})

function DraftStatus({
  identity,
  model,
  queryKey
}: {
  identity: EditorDraftIdentity
  model: EditorDraftModel<string>
  queryKey: readonly unknown[]
}) {
  const query = useQuery<DraftCache>({ queryKey, queryFn: async () => ({}), enabled: false })
  const status = useEditorDraft(model, {
    identity,
    source: query.data?.source,
    absent: () => query.data?.absent === true
  })
  return <span>{status}</span>
}

function renderStatus(
  queryClient: QueryClient,
  queryKey: readonly unknown[],
  model: EditorDraftModel<string>,
  identity: EditorDraftIdentity
) {
  return renderToStaticMarkup(
    <QueryClientProvider client={queryClient}>
      <DraftStatus identity={identity} model={model} queryKey={queryKey} />
    </QueryClientProvider>
  )
}

function freshQueryClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 60_000 } } })
}

function fakeModel(sourceKey?: string): EditorDraftModel<string> {
  return {
    sourceKey: { value: sourceKey },
    initialize(key) {
      this.sourceKey.value = key
    }
  }
}

function recordingModel(sourceKeyForInitialize: (key: string) => string = key => key) {
  const model: EditorDraftModel<string> & { initializations: Array<{ key: string; source: string }> } = {
    sourceKey: { value: undefined },
    initializations: [],
    initialize(key, source) {
      model.initializations.push({ key, source })
      model.sourceKey.value = sourceKeyForInitialize(key)
    }
  }
  return model
}
