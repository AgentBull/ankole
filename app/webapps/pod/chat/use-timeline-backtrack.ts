import { useEffect, useRef, type KeyboardEvent as ReactKeyboardEvent, type RefObject } from 'react'
import type { ConversationDetail } from '../api'
import type { ChatCommands } from '../chat-commands'
import type { ChatModel } from '../state/chat'
import type { TimelineMessage } from './types'

export const BACKTRACK_DOUBLE_ESCAPE_MS = 600

type OverlaySearchable = {
  closest(selector: string): { contains(other: Node | null): boolean } | null
}

function isOverlaySearchable(target: unknown): target is OverlaySearchable {
  return typeof target === 'object' && target !== null && 'closest' in target && typeof target.closest === 'function'
}

export function shouldYieldBacktrackToOverlay(target: unknown, container: Node | null): boolean {
  if (!isOverlaySearchable(target)) return false
  const popup = target.closest('[role="dialog"], [role="alertdialog"], [role="listbox"], [role="menu"]')
  if (!popup) return false
  if (container && popup.contains(container)) return false
  return true
}

export function consumeEmptyComposerEscape({
  now,
  lastEscapeAt,
  canEnterBacktrack,
  enterBacktrack
}: {
  now: number
  lastEscapeAt: number | null
  canEnterBacktrack: boolean
  enterBacktrack: () => boolean
}): { handled: boolean; nextLastEscapeAt: number | null } {
  if (!canEnterBacktrack) {
    return { handled: false, nextLastEscapeAt: null }
  }
  if (lastEscapeAt !== null && Math.abs(now - lastEscapeAt) <= BACKTRACK_DOUBLE_ESCAPE_MS) {
    return { handled: enterBacktrack(), nextLastEscapeAt: null }
  }
  return { handled: true, nextLastEscapeAt: now }
}

export function useComposerBacktrackChord({
  model,
  detail,
  commands
}: {
  model: InstanceType<typeof ChatModel>
  detail?: ConversationDetail
  commands: ChatCommands
}) {
  const lastEscapeAt = useRef<number | null>(null)
  const conversationID = detail?.conversation.id

  useEffect(() => {
    lastEscapeAt.current = null
  }, [model, conversationID])

  const reset = () => {
    lastEscapeAt.current = null
  }

  const handleKeyDown = (event: ReactKeyboardEvent<HTMLTextAreaElement>): boolean => {
    if (event.key !== 'Escape') {
      lastEscapeAt.current = null
      return false
    }
    if (model.backtrackMessageID.value) {
      event.preventDefault()
      event.stopPropagation()
      model.clearBacktrack()
      lastEscapeAt.current = null
      return true
    }
    if (
      event.shiftKey ||
      event.altKey ||
      event.ctrlKey ||
      event.metaKey ||
      event.repeat ||
      model.editing.value ||
      model.answeringInteractionID.value ||
      model.draft.value ||
      model.attachments.hasFiles.value ||
      model.links.value.length > 0 ||
      !detail
    ) {
      lastEscapeAt.current = null
      return false
    }
    const next = consumeEmptyComposerEscape({
      now: event.timeStamp,
      lastEscapeAt: lastEscapeAt.current,
      canEnterBacktrack: commands.editableMessageIDs.length > 0,
      enterBacktrack: commands.enterBacktrack
    })
    lastEscapeAt.current = next.nextLastEscapeAt
    if (next.handled) {
      event.preventDefault()
      event.stopPropagation()
      return true
    }
    return false
  }

  return { reset, handleKeyDown }
}

export function useTimelineBacktrack({
  containerRef,
  fallbackRef,
  scrollRef,
  model,
  editableMessageIDs,
  committedByID,
  onEdit,
  onReturnFocusToComposer
}: {
  containerRef?: RefObject<HTMLElement | null>
  fallbackRef: RefObject<HTMLElement | null>
  scrollRef: RefObject<HTMLElement | null>
  model: InstanceType<typeof ChatModel>
  editableMessageIDs?: string[]
  committedByID: ReadonlyMap<string, TimelineMessage>
  onEdit?: (message: TimelineMessage) => void
  onReturnFocusToComposer?: () => void
}) {
  const backtrackID = model.backtrackMessageID.value

  useEffect(() => () => model.clearBacktrack(), [model])

  useEffect(() => {
    if (!backtrackID) return
    const element = scrollRef.current?.querySelector<HTMLElement>(`[data-chat-message-id="${CSS.escape(backtrackID)}"]`)
    element?.scrollIntoView({ block: 'nearest' })
    element?.focus({ preventScroll: true })
  }, [backtrackID, scrollRef])

  useEffect(() => {
    if (!backtrackID) return
    const container = containerRef?.current ?? fallbackRef.current
    if (!container) return

    const onKeyDown = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented ||
        event.isComposing ||
        event.keyCode === 229 ||
        event.altKey ||
        event.ctrlKey ||
        event.metaKey ||
        event.shiftKey
      ) {
        return
      }
      if (shouldYieldBacktrackToOverlay(event.target, container)) {
        return
      }
      const target = event.target
      if (target instanceof HTMLElement && (target.isContentEditable || target.closest('input, textarea, select'))) {
        return
      }
      if (event.key === 'ArrowUp') {
        event.preventDefault()
        event.stopPropagation()
        model.stepBacktrack(editableMessageIDs ?? [], -1)
      } else if (event.key === 'ArrowDown') {
        event.preventDefault()
        event.stopPropagation()
        model.stepBacktrack(editableMessageIDs ?? [], 1)
      } else if (event.key === 'Enter') {
        const message = committedByID.get(backtrackID)
        if (message && onEdit) {
          event.preventDefault()
          event.stopPropagation()
          onEdit(message)
        }
      } else if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        model.clearBacktrack()
        onReturnFocusToComposer?.()
      }
    }

    const onPointerDown = (event: PointerEvent) => {
      const target = event.target instanceof Element ? event.target : null
      if (!target?.closest('[data-backtrack-active="true"]')) {
        model.clearBacktrack()
      }
    }

    container.addEventListener('keydown', onKeyDown)
    document.addEventListener('pointerdown', onPointerDown)
    return () => {
      container.removeEventListener('keydown', onKeyDown)
      document.removeEventListener('pointerdown', onPointerDown)
    }
  }, [
    backtrackID,
    committedByID,
    containerRef,
    editableMessageIDs,
    fallbackRef,
    model,
    onEdit,
    onReturnFocusToComposer
  ])

  return backtrackID
}
