import { batch, createModel, signal } from '@preact/signals-react'

export const AGENT_LIBRARY_DOCUMENT_KINDS = ['mission', 'soul', 'design', 'confidentiality_policy'] as const

export type AgentLibraryDocumentKind = (typeof AGENT_LIBRARY_DOCUMENT_KINDS)[number]

/** Library file names per kind; the policy file uses the backend's CamelCase name. */
export const AGENT_LIBRARY_DOCUMENT_FILES: Record<AgentLibraryDocumentKind, string> = {
  mission: 'MISSION.md',
  soul: 'SOUL.md',
  design: 'DESIGN.md',
  confidentiality_policy: 'ConfidentialityPolicy.md'
}

export function agentLibraryDocumentTitle(kind: AgentLibraryDocumentKind): string {
  return AGENT_LIBRARY_DOCUMENT_FILES[kind].replace(/\.md$/, '')
}

export type AgentLibraryDocumentSnapshot = {
  kind: AgentLibraryDocumentKind
  content: string
  content_hash: string
}

export type AgentLibraryDocumentsSnapshot = Record<AgentLibraryDocumentKind, AgentLibraryDocumentSnapshot>

export type AgentLibraryDocumentSubmission = {
  content: string
  expectedContentHash: string
  revision: number
}

function createDocumentState() {
  return {
    sourceContent: signal(''),
    contentHash: signal(''),
    draft: signal(''),
    editing: signal(false),
    error: signal<string>(),
    conflict: signal(false),
    revision: signal(0)
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
  state.revision.value += 1
}

export const AgentLibraryEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const documents = {
    mission: createDocumentState(),
    soul: createDocumentState(),
    design: createDocumentState(),
    confidentiality_policy: createDocumentState()
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
        state.revision.value += 1
      })
    },
    setDraft(kind: AgentLibraryDocumentKind, content: string) {
      const state = documents[kind]
      if (state.draft.value === content) return
      batch(() => {
        state.draft.value = content
        state.revision.value += 1
      })
    },
    cancel(kind: AgentLibraryDocumentKind) {
      const state = documents[kind]
      batch(() => {
        state.draft.value = state.sourceContent.value
        state.editing.value = false
        state.error.value = undefined
        state.conflict.value = false
        state.revision.value += 1
      })
    },
    markSaved(
      kind: AgentLibraryDocumentKind,
      document: AgentLibraryDocumentSnapshot,
      submission: AgentLibraryDocumentSubmission
    ) {
      const state = documents[kind]
      const hasUnsavedChanges =
        state.editing.value && state.revision.value !== submission.revision && state.draft.value !== document.content

      batch(() => {
        if (!hasUnsavedChanges) {
          replaceDocumentState(state, document)
          return
        }

        state.sourceContent.value = document.content
        state.contentHash.value = document.content_hash
        state.error.value = undefined
        state.conflict.value = false
        state.revision.value += 1
      })

      return { hasUnsavedChanges }
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
    snapshot(kind: AgentLibraryDocumentKind): AgentLibraryDocumentSubmission {
      return {
        content: documents[kind].draft.value,
        expectedContentHash: documents[kind].contentHash.value,
        revision: documents[kind].revision.value
      }
    }
  }
})
