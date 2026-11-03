import { batch, computed, createModel, signal } from '@preact/signals-react'

/** Title writes have their own compare-and-swap baseline, independent of document revisions. */
export const TitleDraftModel = createModel(() => {
  const value = signal('')
  const saved = signal('')
  const base = signal('')
  const conflict = signal(false)
  const dirty = computed(() => value.value.trim() !== saved.value)
  let source = ''
  let sourceTitle = ''
  return {
    value,
    saved,
    base,
    conflict,
    dirty,
    load(id: string, remote: string, stored?: Record<string, unknown>) {
      if (source === id) {
        if (sourceTitle !== remote) {
          if (!dirty.value || value.value.trim() === remote) {
            value.value = remote
            base.value = remote
          }
          saved.value = remote
          sourceTitle = remote
        }
        return
      }
      source = id
      sourceTitle = remote
      const local =
        typeof stored?.title === 'string' && stored.title.trim() !== stored.savedTitle && stored.title.trim() !== remote
          ? stored.title
          : remote
      batch(() => {
        value.value = local
        saved.value = remote
        base.value = local !== remote && typeof stored?.titleBase === 'string' ? stored.titleBase : remote
        conflict.value = base.value !== remote
      })
    },
    acknowledge(confirmed: string, submitted: string) {
      if (value.value.trim() === submitted) value.value = confirmed
      saved.value = confirmed
      base.value = confirmed
      conflict.value = false
    },
    reject(current: string) {
      saved.value = current
      sourceTitle = current
      conflict.value = true
    },
    review(useRemote: boolean) {
      if (useRemote) value.value = saved.value
      base.value = saved.value
      conflict.value = false
    },
    discard() {
      value.value = saved.value
      base.value = saved.value
      conflict.value = false
    }
  }
})
