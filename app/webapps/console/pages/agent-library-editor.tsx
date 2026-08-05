import { Button, Tabs, TabsContent, TabsList, TabsTrigger, Textarea, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiEditLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAgentLibraryControllerIndexQueryKey,
  ankoleWebAgentLibraryControllerIndexOptions,
  ankoleWebAgentLibraryControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { SaveButton } from '../console-form'
import { ErrorBlock } from '../console-primitives'
import {
  AGENT_LIBRARY_DOCUMENT_KINDS,
  AgentLibraryEditorModel,
  type AgentLibraryDocumentKind,
  type AgentLibraryDocumentSnapshot,
  type AgentLibraryDocumentSubmission,
  type AgentLibraryDocumentsSnapshot
} from '../state/agent-library-editor-model'

export function AgentLibraryEditor({ agentUID }: { agentUID: string }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(AgentLibraryEditorModel)
  const queryClient = useQueryClient()
  const currentAgentUID = useRef(agentUID)
  currentAgentUID.current = agentUID
  const pendingSubmissions = useRef(new Map<string, AgentLibraryDocumentSubmission>())
  const [activeKind, setActiveKind] = useState<AgentLibraryDocumentKind>('mission')
  const documents = useQuery(ankoleWebAgentLibraryControllerIndexOptions({ path: { agent_uid: agentUID } }))
  const replaceDocument = useMutation({
    ...ankoleWebAgentLibraryControllerUpdateMutation(),
    onSuccess: (response, variables) => {
      const savedAgentUID = variables.path.agent_uid
      const kind = variables.path.document_kind as AgentLibraryDocumentKind
      const submissionKey = documentSubmissionKey(savedAgentUID, kind)
      const submission = pendingSubmissions.current.get(submissionKey)
      pendingSubmissions.current.delete(submissionKey)
      const document = response.library_document as AgentLibraryDocumentSnapshot

      if (currentAgentUID.current === savedAgentUID && submission) {
        const result = model.markSaved(document.kind, document, submission)
        const messageKey = result.hasUnsavedChanges ? 'saved_with_unsaved_changes' : 'saved'
        const message = t(`console.agent_library.${messageKey}`, { kind: document.kind.toUpperCase() })
        if (result.hasUnsavedChanges) toast.info(message)
        else toast.success(message)
      }

      void queryClient.invalidateQueries({
        queryKey: ankoleWebAgentLibraryControllerIndexQueryKey({ path: { agent_uid: savedAgentUID } })
      })
    },
    onError: (error, variables) => {
      const savedAgentUID = variables.path.agent_uid
      const kind = variables.path.document_kind as AgentLibraryDocumentKind
      pendingSubmissions.current.delete(documentSubmissionKey(savedAgentUID, kind))
      if (currentAgentUID.current !== savedAgentUID) return
      const conflict = requestErrorCode(error) === 'agent_library_document_conflict'
      model.setError(kind, conflict ? t('console.agent_library.conflict') : requestErrorMessage(error), conflict)
    }
  })

  useEffect(() => {
    if (!documents.data) return
    model.initialize(agentUID, documents.data.library_documents as AgentLibraryDocumentsSnapshot)
  }, [agentUID, documents.data, model])

  useEffect(() => setActiveKind('mission'), [agentUID])

  const save = (kind: AgentLibraryDocumentKind) => {
    const draft = model.snapshot(kind)
    model.setError(kind, '')
    pendingSubmissions.current.set(documentSubmissionKey(agentUID, kind), draft)
    replaceDocument.mutate({
      body: {
        content: draft.content,
        expected_content_hash: draft.expectedContentHash
      },
      path: { agent_uid: agentUID, document_kind: kind }
    })
  }

  const reloadLatest = async (kind: AgentLibraryDocumentKind) => {
    const requestedAgentUID = agentUID
    const result = await documents.refetch()
    if (currentAgentUID.current !== requestedAgentUID) return
    const latest = result.data?.library_documents[kind] as AgentLibraryDocumentSnapshot | undefined
    if (latest) {
      model.reload(kind, latest)
      return
    }
    if (result.error) model.setError(kind, requestErrorMessage(result.error))
  }

  const initialized = model.sourceKey.value === `agent:${agentUID}`

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.agent_library.title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.agent_library.description')}</p>
        <p className="text-xs leading-5 text-muted-foreground">{t('console.agent_library.effect_hint')}</p>
      </div>

      <ErrorBlock error={documents.error} />
      {documents.isLoading ? (
        <span className="text-xs text-muted-foreground">{t('common.loading')}</span>
      ) : initialized ? (
        <Tabs
          className="grid gap-4 border border-border bg-card p-4 md:p-5"
          value={activeKind}
          onValueChange={value => {
            if (isDocumentKind(value)) setActiveKind(value)
          }}>
          <TabsList className="w-full">
            {AGENT_LIBRARY_DOCUMENT_KINDS.map(kind => (
              <TabsTrigger key={kind} value={kind}>
                {kind.toUpperCase()}
              </TabsTrigger>
            ))}
          </TabsList>

          {AGENT_LIBRARY_DOCUMENT_KINDS.map(kind => {
            const state = model.documents[kind]
            return (
              <TabsContent key={kind} value={kind} className="grid gap-4 pt-1">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-mono text-xs text-muted-foreground">{`${kind.toUpperCase()}.md`}</span>
                  {!state.editing.value ? (
                    <Button size="xs" type="button" variant="outline" onClick={() => model.beginEdit(kind)}>
                      <RiEditLine data-icon="inline-start" />
                      {t('common.edit')}
                    </Button>
                  ) : null}
                </div>

                <ErrorBlock
                  error={state.error.value}
                  action={
                    state.conflict.value ? (
                      <Button size="xs" type="button" variant="outline" onClick={() => void reloadLatest(kind)}>
                        {t('console.agent_library.discard_and_reload')}
                      </Button>
                    ) : undefined
                  }
                />

                {state.editing.value ? (
                  <>
                    <Textarea
                      aria-label={kind.toUpperCase()}
                      className="min-h-80 resize-y font-mono text-xs leading-6"
                      spellCheck={false}
                      value={state.draft.value}
                      onChange={event => model.setDraft(kind, event.target.value)}
                    />
                    <div className="flex flex-wrap items-center gap-2">
                      <SaveButton
                        disabled={replaceDocument.isPending || state.draft.value === state.sourceContent.value}
                        loading={replaceDocument.isPending}
                        size="xs"
                        type="button"
                        onClick={() => save(kind)}>
                        {t('common.save')}
                      </SaveButton>
                      <Button size="xs" type="button" variant="ghost" onClick={() => model.cancel(kind)}>
                        {t('common.cancel')}
                      </Button>
                    </div>
                  </>
                ) : state.sourceContent.value ? (
                  <pre className="max-h-[32rem] overflow-auto whitespace-pre-wrap break-words border border-border bg-background p-4 font-mono text-xs leading-6">
                    {state.sourceContent.value}
                  </pre>
                ) : (
                  <div className="border border-dashed border-border p-6 text-sm text-muted-foreground">
                    {t('console.agent_library.empty')}
                  </div>
                )}
              </TabsContent>
            )
          })}
        </Tabs>
      ) : null}
    </section>
  )
}

function isDocumentKind(value: string): value is AgentLibraryDocumentKind {
  return AGENT_LIBRARY_DOCUMENT_KINDS.some(kind => kind === value)
}

function documentSubmissionKey(agentUID: string, kind: AgentLibraryDocumentKind): string {
  return `${agentUID}:${kind}`
}

function requestErrorCode(error: unknown): string | undefined {
  if (!error || typeof error !== 'object' || !('error' in error)) return undefined
  const envelope = (error as { error?: unknown }).error
  if (!envelope || typeof envelope !== 'object' || !('code' in envelope)) return undefined
  const code = (envelope as { code?: unknown }).code
  return typeof code === 'string' ? code : undefined
}
