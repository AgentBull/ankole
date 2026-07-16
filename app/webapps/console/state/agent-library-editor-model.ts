import { batch, createModel, signal } from '@preact/signals-react'

export const AGENT_LIBRARY_DOCUMENT_KINDS = ['mission', 'soul', 'design'] as const

export type AgentLibraryDocumentKind = (typeof AGENT_LIBRARY_DOCUMENT_KINDS)[number]

export type AgentLibraryDocumentSnapshot = {
  kind: AgentLibraryDocumentKind
  content: string
  content_hash: string
}

export type AgentLibraryDocumentsSnapshot = Record<AgentLibraryDocumentKind, AgentLibraryDocumentSnapshot>

function createDocumentState() {
  return {
    sourceContent: signal(''),
    contentHash: signal(''),
    draft: signal(''),
    editing: signal(false),
    error: signal<string>(),
    conflict: signal(false)
  }
}

type DocumentState = ReturnType<typeof createDocumentState>

function replaceDocumentState(state: DocumentState, document: AgentLibraryDocumentSnapshot) {
  state.sourceContent.value = document.content
  state.contentHash.value = document.content_hash
  state.draft.value = document.content
  state.editing.value = false
  state.error.value = undefined
  state.conflict.value = false
}

export const AgentLibraryEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const documents = {
    mission: createDocumentState(),
    soul: createDocumentState(),
    design: createDocumentState()
  } satisfies Record<AgentLibraryDocumentKind, DocumentState>

  return {
    sourceKey,
    documents,
    initialize(agentUID: string, nextDocuments: AgentLibraryDocumentsSnapshot) {
      const nextSourceKey = `agent:${agentUID}`
      batch(() => {
        if (sourceKey.value !== nextSourceKey) {
          sourceKey.value = nextSourceKey
          for (const kind of AGENT_LIBRARY_DOCUMENT_KINDS) replaceDocumentState(documents[kind], nextDocuments[kind])
          return
        }

        for (const kind of AGENT_LIBRARY_DOCUMENT_KINDS) {
          if (!documents[kind].editing.value) replaceDocumentState(documents[kind], nextDocuments[kind])
        }
      })
    },
    beginEdit(kind: AgentLibraryDocumentKind) {
      const state = documents[kind]
      batch(() => {
        state.draft.value = state.sourceContent.value
        state.editing.value = true
        state.error.value = undefined
        state.conflict.value = false
      })
    },
    setDraft(kind: AgentLibraryDocumentKind, content: string) {
      documents[kind].draft.value = content
    },
    cancel(kind: AgentLibraryDocumentKind) {
      const state = documents[kind]
      batch(() => {
        state.draft.value = state.sourceContent.value
        state.editing.value = false
        state.error.value = undefined
        state.conflict.value = false
      })
    },
    markSaved(kind: AgentLibraryDocumentKind, document: AgentLibraryDocumentSnapshot) {
      batch(() => replaceDocumentState(documents[kind], document))
    },
    setError(kind: AgentLibraryDocumentKind, error: string, conflict = false) {
      batch(() => {
        documents[kind].error.value = error
        documents[kind].conflict.value = conflict
      })
    },
    reload(kind: AgentLibraryDocumentKind, document: AgentLibraryDocumentSnapshot) {
      batch(() => replaceDocumentState(documents[kind], document))
    },
    snapshot(kind: AgentLibraryDocumentKind) {
      return {
        content: documents[kind].draft.value,
        expectedContentHash: documents[kind].contentHash.value
      }
    }
  }
})
