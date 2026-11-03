import { batch, computed, createModel, effect, signal } from '@preact/signals-react'

/** A draft keeps its own base revision even while remote queries refresh. */
function createDocumentDraft() {
  let reloadVersion = 0
  effect(() => () => {
    reloadVersion++
  })
  const xml = signal('<page/>')
  const savedXML = signal('<page/>')
  const revision = signal(0)
  const source = signal('')
  const conflict = signal(false)
  const bodyPending = signal(false)
  const recoveryDrafts = signal<readonly string[]>([])
  const bodyReady = computed(() => !bodyPending.value && !conflict.value && xml.value === savedXML.value)
  const dirty = computed(() => xml.value !== savedXML.value)
  const hasUnsavedChanges = computed(() => dirty.value || bodyPending.value || recoveryDrafts.value.length > 0)
  return {
    xml,
    savedXML,
    revision,
    source,
    conflict,
    bodyPending,
    bodyReady,
    recoveryDrafts,
    dirty,
    hasUnsavedChanges,
    discard() {
      reloadVersion++
      batch(() => {
        xml.value = savedXML.value
        recoveryDrafts.value = []
        conflict.value = false
        bodyPending.value = false
      })
    },
    keepRecoveryDraft(content: string) {
      if (!recoveryDrafts.value.includes(content)) recoveryDrafts.value = [...recoveryDrafts.value, content]
    },
    discardRecoveryDraft(content: string) {
      recoveryDrafts.value = recoveryDrafts.value.filter(draft => draft !== content)
    },
    load(id: string, content: string, version: number, stored?: Record<string, unknown>) {
      if (source.value === id) return
      reloadVersion++
      const recovered = Array.isArray(stored?.recoveryDrafts)
        ? stored.recoveryDrafts.filter((draft): draft is string => typeof draft === 'string' && draft !== content)
        : []
      if (
        typeof stored?.xml === 'string' &&
        (stored.pending === true || stored.xml !== stored.savedXML) &&
        stored.xml !== content
      ) {
        recovered.push(stored.xml)
      }
      batch(() => {
        source.value = id
        xml.value = content
        savedXML.value = content
        revision.value = version
        conflict.value = false
        bodyPending.value = false
        recoveryDrafts.value = [...new Set(recovered)]
      })
    },
    saved(content: string, version: number, pending: boolean) {
      batch(() => {
        savedXML.value = content
        revision.value = version
        bodyPending.value = pending
        conflict.value = false
      })
    },
    async reload(request: () => Promise<{ xml: string; revision: number }>) {
      const requestedVersion = ++reloadVersion
      const requestedXML = xml.value
      try {
        const latest = await request()
        if (reloadVersion !== requestedVersion || xml.value !== requestedXML || latest.revision < revision.value) return
        batch(() => {
          xml.value = latest.xml
          savedXML.value = latest.xml
          revision.value = latest.revision
          bodyPending.value = false
          conflict.value = false
        })
        return latest.xml
      } catch (error) {
        if (reloadVersion === requestedVersion && xml.value === requestedXML) throw error
      }
    },
    cancelReload() {
      reloadVersion++
    }
  }
}

export const DocumentDraftModel = createModel(createDocumentDraft)
