import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { createReadDenials } from '@ankole/applet-sdk'
import type { PodChatOpenOptions, PodPrincipal } from '@ankole/applet-sdk/types'
import { podSubjects } from './api/generated/sdk.gen'
import { createBaseAPI } from './base-api'
import { isRealtimeAccessDenied, PodRealtime } from './realtime'
import { contentKeys } from './content-api'
import { applyTreeChange, updatePageMetadata } from './state/navigation-cache'
import { revalidateMentions } from './state/document-mentions'
import { podKeys } from './api'
import { metaKeys, type MetaBrainGraph } from './meta-api'
import { pageHrefFor } from './use-page-metadata'
import type { OfficeNavigationSession } from './office/office-collaboration'

export type PageSaveOptions = {
  syncIfClean: boolean
}

export type PageHostActions = {
  navigateToPage(pageID: string): void
  openChat(options?: PodChatOpenOptions): void
  registerOfficeSession?(session: OfficeNavigationSession): () => void
  registerPageSave?(handler: (options: PageSaveOptions) => Promise<boolean>): () => void
}

export function isSaveShortcut(
  event: Pick<KeyboardEvent, 'key' | 'metaKey' | 'ctrlKey' | 'shiftKey' | 'altKey'>
): boolean {
  if (event.shiftKey || event.altKey) return false
  if (event.metaKey === event.ctrlKey) return false
  return event.key.toLowerCase() === 's'
}

const BLOCKING_SAVE_OVERLAY_SELECTOR =
  '[data-slot="dialog-content"]:not([data-ending-style]), [data-slot="sheet-content"]:not([data-ending-style]), [role="alertdialog"]:not([data-ending-style]), [aria-modal="true"]:not([data-ending-style])'

/**
 * Modal dialogs and sheets own keyboard input while open, except Base's record-details dialog
 * (`.pod-record-dialog` without a create-record `<form>`), which edits an existing Base record in place.
 */
export function hasBlockingSaveOverlay(ownerDoc: Document | undefined = globalThis.document): boolean {
  if (!ownerDoc) return false
  for (const overlay of ownerDoc.querySelectorAll(BLOCKING_SAVE_OVERLAY_SELECTOR)) {
    if (overlay.hasAttribute('hidden')) continue
    if (overlay.classList.contains('pod-record-dialog') && !overlay.querySelector('form')) continue
    return true
  }
  return false
}

export function isSidebarEditorFocus(
  activeElement: Element | null = globalThis.document?.activeElement ?? null
): boolean {
  if (!activeElement || typeof activeElement.closest !== 'function') return false
  return (
    Boolean(activeElement.closest('[data-sidebar]')) &&
    activeElement.matches('input, textarea, select, [contenteditable="true"]')
  )
}

const PageHostContext = createContext<PageHostActions | null>(null)
export const PageHostScope = PageHostContext.Provider
export function usePageHost() {
  return useContext(PageHostContext)
}

const ContentContext = createContext<ReturnType<typeof createContent> | null>(null)
export const ContentScope = ContentContext.Provider
function createContent(client: ReturnType<typeof useQueryClient>) {
  const realtime = new PodRealtime()
  const readDenials = createReadDenials(client.getQueryCache())
  return {
    realtime,
    base: createBaseAPI(client, realtime),
    readDenial: readDenials.get,
    async principals(): Promise<PodPrincipal[]> {
      const { subjects } = await podSubjects()
      return subjects.flatMap(subject =>
        subject.principal_uid && (subject.kind === 'human' || subject.kind === 'agent')
          ? [
              {
                uid: subject.principal_uid,
                name: subject.name,
                kind: subject.kind,
                avatar_url: subject.avatar_url ?? null,
                subtitle: subject.subtitle ?? null,
                membership: subject.membership ?? null
              }
            ]
          : []
      )
    },
    dispose() {
      readDenials.dispose()
      realtime.dispose()
    },
    pageHref(id: string, title?: string | null) {
      return pageHrefFor(client, id, title)
    }
  }
}

export function ContentProvider({ children }: { children: ReactNode }) {
  const client = useQueryClient()
  const [value, setValue] = useState<ReturnType<typeof createContent> | null>(null)
  useEffect(() => {
    const content = createContent(client)
    let disposed = false
    let retry: ReturnType<typeof setTimeout> | undefined
    const refreshConversations = () => {
      if (!disposed) void client.invalidateQueries({ queryKey: podKeys.conversations })
    }
    const refresh = () => {
      if (disposed) return
      // Preserve initial reads; revalidate cached data when subscriptions become ready.
      void client.invalidateQueries({ queryKey: contentKeys.all })
      void client.invalidateQueries({ queryKey: metaKeys.brain() })
      revalidateMentions(client)
      refreshConversations()
    }
    const subscribe = () => {
      void content.realtime.join('content').then(
        handle => {
          if (disposed) return handle.close()
          handle.on('access_changed', refresh)
          handle.on('rejoined', refresh)
          handle.on('tree_changed', payload => {
            if (!disposed) {
              void applyTreeChange(client, payload)
              void client.invalidateQueries({ queryKey: metaKeys.brain() })
            }
          })
          handle.on('page_updated', payload => {
            if (disposed) return
            updatePageMetadata(client, payload)
            const graph = client.getQueryData<MetaBrainGraph>(metaKeys.brain())
            if (
              graph?.nodes.some(node => node.id === payload.id) ||
              graph?.categories.some(category => category.id === payload.id)
            ) {
              void client.invalidateQueries({ queryKey: metaKeys.brain() })
            }
            void client.invalidateQueries({ queryKey: [...contentKeys.all, 'comment-attention'] })
          })
          handle.on('access_revoked', refresh)
          handle.on('conversations_changed', refreshConversations)
          void handle.ready.then(refresh, () => {})
        },
        error => {
          if (!disposed && !isRealtimeAccessDenied(error)) retry = setTimeout(subscribe, 1000)
        }
      )
    }
    subscribe()
    setValue(content)
    return () => {
      disposed = true
      clearTimeout(retry)
      content.dispose()
    }
  }, [client])
  return value && <ContentContext value={value}>{children}</ContentContext>
}

export function useContent() {
  const value = useContext(ContentContext)
  if (!value) throw new Error('Pod content provider is missing')
  return value
}
