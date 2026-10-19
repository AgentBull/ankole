import { batch, createModel, signal } from '@preact/signals-react'
import type { ViewConfig } from './view-config'

export const TableWorkspaceModel = createModel(() => {
  const viewID = signal('')
  const draft = signal<{ config: ViewConfig; version: number }>()
  const pageToken = signal<string>()
  const history = signal<(string | undefined)[]>([])
  const newRecord = signal(false)
  let initialized = false
  return {
    viewID,
    draft,
    pageToken,
    history,
    newRecord,
    load(initialView?: string) {
      if (!initialized) {
        initialized = true
        viewID.value = initialView ?? ''
      }
    },
    resetPages() {
      batch(() => {
        pageToken.value = undefined
        history.value = []
      })
    },
    select(id: string) {
      batch(() => {
        viewID.value = id
        draft.value = undefined
        newRecord.value = false
        pageToken.value = undefined
        history.value = []
      })
    },
    configure(config: ViewConfig, version: number) {
      batch(() => {
        draft.value = { config, version: draft.value?.version ?? version }
        pageToken.value = undefined
        history.value = []
      })
    },
    discard() {
      batch(() => {
        draft.value = undefined
        pageToken.value = undefined
        history.value = []
      })
    },
    previous() {
      batch(() => {
        pageToken.value = history.value.at(-1)
        history.value = history.value.slice(0, -1)
      })
    },
    next(token: string) {
      batch(() => {
        history.value = [...history.value, pageToken.value]
        pageToken.value = token
      })
    }
  }
})
