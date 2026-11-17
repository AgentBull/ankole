import { computed, createModel, effect, signal } from '@preact/signals-react'
import { documentStats, textStats, type EditingStats } from './document-tools'
import type { DocumentDraftModel } from './document-draft'

const STATS_DEBOUNCE_MS = 150
const EMPTY_STATS: EditingStats = { words: 0, characters: 0, paragraphs: 0, readingTime: 0 }

/** Document tools read the live draft, including edits awaiting OT acknowledgement. */
export const DocumentToolsModel = createModel(
  (draft: InstanceType<typeof DocumentDraftModel>, preferenceKey?: string) => {
    let stored = false
    try {
      stored = !!preferenceKey && localStorage.getItem(preferenceKey) === 'true'
    } catch {
      // The preference still works for this page when browser storage is unavailable.
    }
    const showStats = signal(stored)
    const selectedText = signal('')
    const debouncedXml = signal(stored ? draft.xml.value : '')

    let timer: ReturnType<typeof setTimeout> | undefined
    let activeSource: string | null = null
    const clearTimer = () => {
      if (timer !== undefined) {
        clearTimeout(timer)
        timer = undefined
      }
    }

    const stopSync = effect(() => {
      const enabled = showStats.value
      const xml = draft.xml.value
      const source = draft.source.value
      clearTimer()
      if (!enabled) {
        activeSource = null
        return
      }
      if (activeSource !== source || debouncedXml.peek() === xml) {
        activeSource = source
        debouncedXml.value = xml
        return
      }
      timer = setTimeout(() => {
        timer = undefined
        debouncedXml.value = xml
      }, STATS_DEBOUNCE_MS)
      return clearTimer
    })

    const wholeStats = computed<EditingStats>(() => (showStats.value ? documentStats(debouncedXml.value) : EMPTY_STATS))
    const stats = computed<EditingStats>(() => {
      if (!showStats.value) return EMPTY_STATS
      const selected = selectedText.value
      return selected ? textStats(selected) : wholeStats.value
    })

    return {
      showStats,
      selectedText,
      stats,
      setShowStats(show: boolean) {
        if (show && !showStats.peek()) {
          clearTimer()
          activeSource = draft.source.peek()
          debouncedXml.value = draft.xml.peek()
        } else if (!show) {
          clearTimer()
          activeSource = null
        }
        showStats.value = show
        try {
          if (preferenceKey) localStorage.setItem(preferenceKey, String(show))
        } catch {
          // A storage failure must not undo the user's current choice.
        }
      },
      dispose() {
        clearTimer()
        stopSync()
      }
    }
  }
)
