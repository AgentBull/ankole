import { batch, computed, createModel, signal } from '@preact/signals-react'

/** A draft keeps its own base revision even while remote queries refresh. */
export const PageDraftModel = createModel(() => {
  const xml = signal('<page/>')
  const savedXML = signal('<page/>')
  const revision = signal(0)
  const source = signal('')
  const title = signal('')
  const savedTitle = signal('')
  const sourceTitle = signal('')
  const conflict = signal(false)
  const recoveryDrafts = signal<readonly string[]>([])
  const titleDirty = computed(() => title.value.trim() !== savedTitle.value)
  const dirty = computed(() => titleDirty.value || xml.value !== savedXML.value)
  const hasUnsavedChanges = computed(() => dirty.value || recoveryDrafts.value.length > 0)
  return {
    xml,
    savedXML,
    revision,
    source,
    title,
    savedTitle,
    titleDirty,
    conflict,
    recoveryDrafts,
    dirty,
    hasUnsavedChanges,
    keepRecoveryDraft(content: string) {
      if (!recoveryDrafts.value.includes(content)) recoveryDrafts.value = [...recoveryDrafts.value, content]
    },
    discardRecoveryDraft(content: string) {
      recoveryDrafts.value = recoveryDrafts.value.filter(draft => draft !== content)
    },
    load(id: string, content: string, version: number, remoteTitle = '') {
      if (source.value === id) {
        if (sourceTitle.value !== remoteTitle) {
          batch(() => {
            if (!titleDirty.value) title.value = remoteTitle
            savedTitle.value = remoteTitle
            sourceTitle.value = remoteTitle
          })
        }
        return
      }
      batch(() => {
        source.value = id
        xml.value = content
        savedXML.value = content
        revision.value = version
        title.value = remoteTitle
        savedTitle.value = remoteTitle
        sourceTitle.value = remoteTitle
        conflict.value = false
        recoveryDrafts.value = []
      })
    },
    titleSaved(value: string) {
      savedTitle.value = value
    },
    saved(content: string, version: number) {
      batch(() => {
        savedXML.value = content
        revision.value = version
        conflict.value = false
      })
    },
    reload(content: string, version: number) {
      batch(() => {
        xml.value = content
        savedXML.value = content
        revision.value = version
        conflict.value = false
      })
    }
  }
})
