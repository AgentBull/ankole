import { batch, computed, createModel, signal } from '@preact/signals-react'
import { recordValue, safeJsonParse } from '@agentbull/active-support'

/** A draft keeps its own base revision even while remote queries refresh. */
export const PageDraftModel = createModel((storageKey?: string) => {
  let reloadVersion = 0
  const xml = signal('<page/>')
  const savedXML = signal('<page/>')
  const revision = signal(0)
  const source = signal('')
  const title = signal('')
  const savedTitle = signal('')
  const titleBase = signal('')
  const titleConflict = signal(false)
  const sourceTitle = signal('')
  const conflict = signal(false)
  const bodyPending = signal(false)
  const recoveryDrafts = signal<readonly string[]>([])
  const storageError = signal(false)
  const bodyReady = computed(() => !bodyPending.value && !conflict.value && xml.value === savedXML.value)
  const titleDirty = computed(() => title.value.trim() !== savedTitle.value)
  const dirty = computed(() => titleDirty.value || xml.value !== savedXML.value)
  const hasUnsavedChanges = computed(() => dirty.value || bodyPending.value || recoveryDrafts.value.length > 0)
  return {
    xml,
    savedXML,
    revision,
    source,
    title,
    savedTitle,
    titleBase,
    titleConflict,
    titleDirty,
    conflict,
    bodyPending,
    bodyReady,
    recoveryDrafts,
    storageError,
    dirty,
    hasUnsavedChanges,
    persist() {
      if (!storageKey || !source.peek()) return
      try {
        if (hasUnsavedChanges.peek()) {
          sessionStorage.setItem(
            storageKey,
            JSON.stringify({
              xml: xml.peek(),
              savedXML: savedXML.peek(),
              pending: bodyPending.peek(),
              title: title.peek(),
              savedTitle: savedTitle.peek(),
              titleBase: titleBase.peek(),
              recoveryDrafts: recoveryDrafts.peek()
            })
          )
        } else {
          sessionStorage.removeItem(storageKey)
        }
        storageError.value = false
      } catch {
        storageError.value = true
      }
    },
    discard() {
      reloadVersion++
      batch(() => {
        title.value = savedTitle.value
        titleBase.value = savedTitle.value
        titleConflict.value = false
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
    load(id: string, content: string, version: number, remoteTitle = '') {
      if (source.value === id) {
        if (sourceTitle.value !== remoteTitle) {
          batch(() => {
            if (!titleDirty.value || title.value.trim() === remoteTitle) {
              title.value = remoteTitle
              titleBase.value = remoteTitle
            }
            savedTitle.value = remoteTitle
            sourceTitle.value = remoteTitle
          })
        }
        return
      }
      reloadVersion++
      let stored: Record<string, unknown> | undefined
      if (storageKey) {
        try {
          stored = recordValue(safeJsonParse(sessionStorage.getItem(storageKey) ?? '').unwrapOr(undefined))
        } catch {
          storageError.value = true
        }
      }
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
      const localTitle =
        typeof stored?.title === 'string' &&
        stored.title.trim() !== stored.savedTitle &&
        stored.title.trim() !== remoteTitle
          ? stored.title
          : remoteTitle
      const localBase =
        localTitle !== remoteTitle && typeof stored?.titleBase === 'string' ? stored.titleBase : remoteTitle
      batch(() => {
        source.value = id
        xml.value = content
        savedXML.value = content
        revision.value = version
        title.value = localTitle
        titleBase.value = localBase
        titleConflict.value = localBase !== remoteTitle
        savedTitle.value = remoteTitle
        sourceTitle.value = remoteTitle
        conflict.value = false
        bodyPending.value = false
        recoveryDrafts.value = [...new Set(recovered)]
      })
    },
    titleSaved(value: string) {
      batch(() => {
        savedTitle.value = value
        titleBase.value = value
        titleConflict.value = false
      })
    },
    titleRejected(current: string) {
      batch(() => {
        savedTitle.value = current
        sourceTitle.value = current
        titleConflict.value = true
      })
    },
    reviewTitle(useRemote: boolean) {
      batch(() => {
        if (useRemote) title.value = savedTitle.value
        titleBase.value = savedTitle.value
        titleConflict.value = false
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
})
