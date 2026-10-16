import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider, useQuery } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import type { EditorDraftModel } from './use-editor-draft'
import { seedEditorDraft, useEditorDraft } from './use-editor-draft'

type DraftCache = { source?: string; absent?: boolean }

describe('useEditorDraft', () => {
  test('accepts the resource owner source key without interpreting its format', () => {
    const queryClient = freshQueryClient()
    const queryKey = ['editor-draft', 'cached'] as const
    queryClient.setQueryData<DraftCache>(queryKey, { source: 'cached' })
    const sourceKey = 'opaque key / selected version 3'
    expect(renderStatus(queryClient, queryKey, recordingModel(sourceKey), sourceKey)).toContain('>ready<')
  })

  test('distinguishes a pending source from a confirmed absent resource', () => {
    const queryClient = freshQueryClient()
    const queryKey = ['editor-draft', 'lookup'] as const
    const model = recordingModel()
    queryClient.setQueryData<DraftCache>(queryKey, {})
    expect(renderStatus(queryClient, queryKey, model, 'selected')).toContain('>loading<')
    queryClient.setQueryData<DraftCache>(queryKey, { absent: true })
    expect(renderStatus(queryClient, queryKey, model, 'selected')).toContain('>absent<')
  })

  test('does not replace a seeded draft when the same query refetches', () => {
    const model = recordingModel()
    seedEditorDraft(model, 'selected', 'cached', false)
    seedEditorDraft(model, 'selected', 'refetched', false)
    expect(model.initializations).toEqual([{ key: 'selected', source: 'cached' }])
  })

  test('revokes a previous draft when the selected source is loading or absent', () => {
    for (const absent of [false, true]) {
      const model = recordingModel()
      let resets = 0
      model.resetSource = () => {
        resets += 1
        model.sourceKey.value = undefined
      }
      seedEditorDraft(model, 'tenant:A', 'A source', false)
      seedEditorDraft(model, 'global:B', undefined, absent)
      expect(resets).toBe(1)
      expect(model.sourceKey.value).toBeUndefined()
      expect(model.initializations).toEqual([{ key: 'tenant:A', source: 'A source' }])
      seedEditorDraft(model, 'global:B', undefined, absent)
      expect(resets).toBe(1)
    }
  })

  test('a pending refetch of the same selection keeps its loaded draft', () => {
    const model = recordingModel()
    model.resetSource = () => {
      throw new Error('same-selection loading must retain the draft')
    }
    seedEditorDraft(model, 'selected', 'source', false)
    seedEditorDraft(model, 'selected', undefined, false)
    expect(model.sourceKey.value).toBe('selected')
  })

  test('initializes each selection with its exact source key', () => {
    const model = recordingModel()
    seedEditorDraft(model, 'agent:ada', 'Ada', false)
    seedEditorDraft(model, 'agent:grace', 'Grace', false)
    expect(model.initializations).toEqual([
      { key: 'agent:ada', source: 'Ada' },
      { key: 'agent:grace', source: 'Grace' }
    ])
  })
})

function DraftStatus({
  sourceKey,
  model,
  queryKey
}: {
  sourceKey: string
  model: EditorDraftModel<string>
  queryKey: readonly unknown[]
}) {
  const query = useQuery<DraftCache>({ queryKey, queryFn: async () => ({}), enabled: false })
  const status = useEditorDraft(model, {
    sourceKey,
    source: query.data?.source,
    absent: () => query.data?.absent === true
  })
  return <span>{status}</span>
}

function renderStatus(
  queryClient: QueryClient,
  queryKey: readonly unknown[],
  model: EditorDraftModel<string>,
  sourceKey: string
) {
  return renderToStaticMarkup(
    <QueryClientProvider client={queryClient}>
      <DraftStatus sourceKey={sourceKey} model={model} queryKey={queryKey} />
    </QueryClientProvider>
  )
}

function freshQueryClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 60_000 } } })
}

function recordingModel(sourceKey?: string) {
  const model: EditorDraftModel<string> & { initializations: Array<{ key: string; source: string }> } = {
    sourceKey: { value: sourceKey },
    initializations: [],
    initialize(key, source) {
      model.initializations.push({ key, source })
      model.sourceKey.value = key
    }
  }
  return model
}
