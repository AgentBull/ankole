import { useEffect, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { createPortal } from 'react-dom'
import { Button } from '@ankole/uikit/components/button'
import { Input } from '@ankole/uikit/components/input'
import { composingKey } from '@ankole/uikit/lib/keyboard'
import { ArrowClockwiseRegular, OpenRegular } from '@ankole/uikit/icons'
import { closeResourceEditor, resourceEditorField } from '../blocks/resources'
import type { ResourceView } from '../document/resources'
import { BlockSelection } from '../editor/block-selection'
import { unitAt } from '../editor/block-target'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel } from './context'
import { LinkViewDropdown, rovingToolbarKeyDown } from './link-view-menu'

export const MIN_EMBED_HEIGHT = 160
export const MAX_EMBED_HEIGHT = 1600
export const DEFAULT_EMBED_HEIGHT = 480

export type ResourceTitleKey = 'media_title' | 'bookmark_title' | 'embed_title'

export function parseSavedEmbedHeight(rawHeight?: string): number {
  const parsed = rawHeight ? Number.parseInt(rawHeight, 10) : NaN
  return Number.isFinite(parsed) && parsed >= MIN_EMBED_HEIGHT && parsed <= MAX_EMBED_HEIGHT
    ? parsed
    : DEFAULT_EMBED_HEIGHT
}

function isSameOriginFrame(frameSrc: string): boolean {
  if (typeof window === 'undefined') return false
  try {
    return new URL(frameSrc, window.location.href).origin === window.location.origin
  } catch {
    return true
  }
}

export function useResourceBlockController({
  container,
  openKey,
  readOnly,
  selected,
  initialEditing,
  onOpenFromCommand
}: {
  container: Element
  openKey: number
  readOnly: boolean
  selected: boolean
  initialEditing: boolean
  onOpenFromCommand: () => void
}) {
  const editor = useEditor()
  const [editing, setEditing] = useState(initialEditing)
  const [hovered, setHovered] = useState(false)
  const [toolbarHovered, setToolbarHovered] = useState(false)
  const [toolbarFocused, setToolbarFocused] = useState(false)
  const [viewMenuOpen, setViewMenuOpen] = useState(false)
  const [selectionDismissed, setSelectionDismissed] = useState(false)

  const blockRef = useRef<HTMLDivElement>(null)
  const addressInputRef = useRef<HTMLInputElement>(null)
  const hoverTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const lastOpenKey = useRef(0)
  const pendingFocus = useRef(false)
  const alive = useRef(true)

  const clearHoverTimer = () => {
    if (hoverTimer.current !== null) {
      clearTimeout(hoverTimer.current)
      hoverTimer.current = null
    }
  }

  const scheduleLeave = (setter: (value: boolean) => void) => {
    clearHoverTimer()
    hoverTimer.current = setTimeout(() => {
      hoverTimer.current = null
      setter(false)
    }, 160)
  }

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
      clearHoverTimer()
    }
  }, [])

  useLayoutEffect(() => {
    if (!openKey) {
      lastOpenKey.current = 0
      return
    }
    if (openKey === lastOpenKey.current || readOnly) return
    lastOpenKey.current = openKey
    pendingFocus.current = true
    onOpenFromCommand()
    setEditing(true)
  }, [openKey, readOnly])

  useLayoutEffect(() => {
    if (!pendingFocus.current || !editing || readOnly) return
    pendingFocus.current = false
    addressInputRef.current?.focus()
    addressInputRef.current?.select()
    const frame = requestAnimationFrame(() => {
      if (!container.contains(document.activeElement)) {
        addressInputRef.current?.focus()
        addressInputRef.current?.select()
      }
    })
    return () => cancelAnimationFrame(frame)
  }, [openKey, editing, readOnly, container])

  useEffect(() => {
    if (!selected) setSelectionDismissed(false)
  }, [selected])

  const selectThisBlock = () => {
    setSelectionDismissed(false)
    if (readOnly || !container.isConnected) return
    const found = editor.nodeFromDOM(container)
    const unit = found && unitAt(editor.state.doc, found.pos, 1)
    const nextSel = unit && BlockSelection.between(editor.state.doc, unit.before, unit.before)
    if (nextSel) {
      editor.dispatch({ selection: nextSel, userEvent: 'select.block' })
      editor.focus()
    }
  }

  const finishCloseEditor = (selectBlock: boolean) => {
    setEditing(false)
    if (selectBlock) setSelectionDismissed(false)
    if (!container.isConnected) return
    const target = editor.nodeFromDOM(container)
    const unit = selectBlock && target ? unitAt(editor.state.doc, target.pos, 1) : null
    const nextSel = unit && BlockSelection.between(editor.state.doc, unit.before, unit.before)
    const hasOpen = (editor.state.field(resourceEditorField, false) ?? null) !== null
    if (hasOpen || nextSel) {
      editor.dispatch({
        ...(hasOpen ? { effects: closeResourceEditor.of(null) } : {}),
        ...(nextSel ? { selection: nextSel, userEvent: 'select.block' } : {})
      })
    }
    editor.focus()
  }

  const startEditing = () => {
    pendingFocus.current = true
    onOpenFromCommand()
    setEditing(true)
  }

  const dismissToolbar = () => {
    setHovered(false)
    setToolbarHovered(false)
    setToolbarFocused(false)
    setSelectionDismissed(true)
    editor.focus()
  }

  return {
    editor,
    alive,
    editing,
    setEditing,
    viewMenuOpen,
    setViewMenuOpen,
    activeHoverOrFocus: hovered || toolbarHovered || toolbarFocused || viewMenuOpen,
    showToolbarForSelection: selected && !selectionDismissed,
    blockRef,
    addressInputRef,
    clearHoverTimer,
    scheduleLeave,
    setHovered,
    setToolbarHovered,
    setToolbarFocused,
    selectThisBlock,
    finishCloseEditor,
    startEditing,
    dismissToolbar
  }
}

export function EmbedFrame({
  frameSrc,
  title,
  reloadKey,
  resizable,
  savedHeight,
  onDraggingChange,
  onDisplayHeightChange,
  onCommitHeight,
  onSelectBlock
}: {
  frameSrc: string
  title: string
  reloadKey: number
  resizable: boolean
  savedHeight: number
  onDraggingChange?: (dragging: boolean) => void
  onDisplayHeightChange?: (height: number) => void
  onCommitHeight?: (height: number) => void
  onSelectBlock?: () => void
}) {
  const label = useEditorLabel()
  const [dragHeight, setDragHeight] = useState<number | null>(null)
  const dragState = useRef<{ pointerId: number; startY: number; startHeight: number; moved: boolean } | null>(null)
  const activeHeight = dragHeight ?? savedHeight
  const sameOrigin = isSameOriginFrame(frameSrc)

  const updateDrag = (nextHeight: number | null) => {
    setDragHeight(nextHeight)
    onDraggingChange?.(nextHeight !== null)
    onDisplayHeightChange?.(nextHeight ?? savedHeight)
  }

  return (
    <div className="resource-frame-wrap" data-resizing={dragHeight !== null ? 'true' : undefined}>
      <iframe
        key={reloadKey}
        className="resource-frame"
        src={frameSrc}
        title={title}
        style={{ height: `${activeHeight}px` }}
        loading="lazy"
        allowFullScreen
        sandbox={
          sameOrigin
            ? 'allow-scripts allow-popups allow-forms'
            : 'allow-scripts allow-same-origin allow-popups allow-forms'
        }
        allow="fullscreen; picture-in-picture; encrypted-media"
        referrerPolicy="strict-origin-when-cross-origin"
      />
      {dragHeight !== null && <div className="resource-frame-shield" aria-hidden="true" />}
      {resizable && (
        <div
          role="separator"
          aria-orientation="horizontal"
          aria-label={label('resource_resize')}
          aria-valuemin={MIN_EMBED_HEIGHT}
          aria-valuemax={MAX_EMBED_HEIGHT}
          aria-valuenow={activeHeight}
          tabIndex={0}
          className="resource-resize-handle"
          onPointerDown={event => {
            if (event.button !== 0) return
            event.preventDefault()
            event.stopPropagation()
            event.currentTarget.setPointerCapture(event.pointerId)
            dragState.current = {
              pointerId: event.pointerId,
              startY: event.clientY,
              startHeight: savedHeight,
              moved: false
            }
            updateDrag(savedHeight)
          }}
          onPointerMove={event => {
            const active = dragState.current
            if (!active || active.pointerId !== event.pointerId) return
            const delta = event.clientY - active.startY
            if (Math.abs(delta) >= 3) active.moved = true
            const next = Math.round(Math.max(MIN_EMBED_HEIGHT, Math.min(MAX_EMBED_HEIGHT, active.startHeight + delta)))
            updateDrag(next)
          }}
          onPointerUp={event => {
            const active = dragState.current
            if (!active || active.pointerId !== event.pointerId) return
            dragState.current = null
            const delta = event.clientY - active.startY
            const finalHeight = Math.round(
              Math.max(MIN_EMBED_HEIGHT, Math.min(MAX_EMBED_HEIGHT, active.startHeight + delta))
            )
            updateDrag(null)
            if (active.moved) {
              if (finalHeight !== savedHeight) onCommitHeight?.(finalHeight)
            } else {
              onSelectBlock?.()
            }
          }}
          onPointerCancel={() => {
            dragState.current = null
            updateDrag(null)
          }}
          onLostPointerCapture={() => {
            dragState.current = null
            updateDrag(null)
          }}
          onKeyDown={event => {
            if (event.key === 'Escape' && dragState.current) {
              event.preventDefault()
              event.stopPropagation()
              dragState.current = null
              updateDrag(null)
              return
            }
            if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
              event.preventDefault()
              event.stopPropagation()
              const step = event.shiftKey ? 64 : 24
              const next = Math.max(
                MIN_EMBED_HEIGHT,
                Math.min(MAX_EMBED_HEIGHT, savedHeight + (event.key === 'ArrowDown' ? step : -step))
              )
              if (next !== savedHeight) onCommitHeight?.(next)
            }
          }}
        />
      )}
    </div>
  )
}

export function ResourceBlockContainer({
  blockRef,
  kind,
  view,
  selected,
  editing,
  readOnly,
  container,
  onPointerEnter,
  onPointerLeave,
  onSelectBlock,
  children
}: {
  blockRef: RefObject<HTMLDivElement | null>
  kind: 'media' | 'embed'
  view: ResourceView
  selected: boolean
  editing: boolean
  readOnly: boolean
  container: Element
  onPointerEnter: () => void
  onPointerLeave: () => void
  onSelectBlock: () => void
  children: ReactNode
}) {
  return (
    <div
      ref={blockRef}
      className="resource-block"
      data-kind={kind}
      data-view={view}
      data-selected={selected ? 'true' : undefined}
      onPointerEnter={onPointerEnter}
      onPointerLeave={onPointerLeave}
      onMouseDown={event => event.stopPropagation()}
      onClick={event => {
        event.stopPropagation()
        if (editing || readOnly || !container.isConnected) return
        const target = event.target instanceof Element ? event.target : null
        if (target?.closest('a, button, input, iframe, video, [role="menuitem"], [role="separator"]')) return
        onSelectBlock()
      }}
      onKeyDown={event => event.stopPropagation()}
      onPaste={event => event.stopPropagation()}
      onDrop={event => event.stopPropagation()}>
      {children}
    </div>
  )
}

export function ResourceFloatingToolbar({
  open,
  anchorRef,
  titleKey,
  src,
  readOnly,
  hasFramePreview,
  showViewMenu,
  view,
  views,
  viewMenuOpen,
  layoutDependency,
  onOpenChangeViewMenu,
  onSelectView,
  onReload,
  onEdit,
  onPointerEnter,
  onPointerLeave,
  onFocusChange,
  onDismiss
}: {
  open: boolean
  anchorRef: RefObject<HTMLDivElement | null>
  titleKey: ResourceTitleKey
  src: string | null
  readOnly: boolean
  hasFramePreview: boolean
  showViewMenu: boolean
  view: ResourceView
  views: readonly ResourceView[]
  viewMenuOpen: boolean
  layoutDependency: number
  onOpenChangeViewMenu: (open: boolean) => void
  onSelectView: (view: ResourceView) => void
  onReload: () => void
  onEdit: () => void
  onPointerEnter: () => void
  onPointerLeave: () => void
  onFocusChange: (focused: boolean) => void
  onDismiss: () => void
}) {
  const editor = useEditor()
  const label = useEditorLabel()
  const toolbarRef = useRef<HTMLDivElement>(null)

  const toolbarPosition = useAnchoredOverlay({
    open,
    panelRef: toolbarRef,
    anchor: () => anchorRef.current?.getBoundingClientRect() ?? null,
    align: 'center',
    side: 'top',
    sideOffset: 8,
    observe: () => anchorRef.current,
    dependencies: [view, hasFramePreview, readOnly, showViewMenu, layoutDependency]
  })

  if (!open || typeof document === 'undefined') return null

  return createPortal(
    <div
      ref={toolbarRef}
      className="selection-toolbar resource-floating-toolbar ankole-editor-overlay ceramic"
      role="toolbar"
      aria-label={label(titleKey)}
      style={toolbarPosition ?? { visibility: 'hidden' }}
      onPointerEnter={onPointerEnter}
      onPointerLeave={onPointerLeave}
      onFocusCapture={() => onFocusChange(true)}
      onBlurCapture={event => {
        if (!event.currentTarget.contains(event.relatedTarget as globalThis.Node | null)) {
          onFocusChange(false)
        }
      }}
      onKeyDown={event => {
        if (
          composingKey(event.nativeEvent) ||
          (event.target instanceof Element && !event.currentTarget.contains(event.target))
        ) {
          return
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          event.stopPropagation()
          onDismiss()
        } else {
          rovingToolbarKeyDown(event)
        }
      }}>
      {hasFramePreview && (
        <>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label={label('resource_refresh')}
            title={label('resource_refresh')}
            onMouseDown={event => event.preventDefault()}
            onClick={onReload}>
            <ArrowClockwiseRegular aria-hidden="true" />
          </Button>
          {src && (
            <a
              className="resource-toolbar-link"
              href={src}
              target="_blank"
              rel="noopener noreferrer"
              aria-label={label('resource_open')}
              title={label('resource_open')}>
              <OpenRegular width={16} height={16} aria-hidden="true" />
            </a>
          )}
          {!readOnly && <span className="toolbar-divider" aria-hidden="true" />}
        </>
      )}
      {!readOnly && (
        <>
          {showViewMenu && (
            <>
              <LinkViewDropdown
                editor={editor}
                current={view}
                views={views}
                triggerClassName="link-view-trigger resource-view-trigger"
                onOpenChange={onOpenChangeViewMenu}
                onMenuPointerEnter={onPointerEnter}
                onMenuPointerLeave={() => {
                  if (!viewMenuOpen) onPointerLeave()
                }}
                onSelect={value => {
                  onOpenChangeViewMenu(false)
                  onSelectView(value)
                }}
              />
              <span className="toolbar-divider" aria-hidden="true" />
            </>
          )}
          <Button variant="ghost" size="xs" onMouseDown={event => event.preventDefault()} onClick={onEdit}>
            {label('resource_edit')}
          </Button>
          {!hasFramePreview && src && (
            <a
              className="resource-toolbar-link"
              href={src}
              target="_blank"
              rel="noopener noreferrer"
              aria-label={label('resource_open')}
              title={label('resource_open')}>
              <OpenRegular width={16} height={16} aria-hidden="true" />
            </a>
          )}
        </>
      )}
    </div>,
    document.body
  )
}

export function ResourceEditForm({
  formId,
  titleKey,
  compact,
  busy,
  error,
  address,
  title,
  addressInputRef,
  uploadControl,
  children,
  onChangeAddress,
  onChangeTitle,
  onSave,
  onCancel
}: {
  formId: string
  titleKey: ResourceTitleKey
  compact: boolean
  busy: boolean
  error: string
  address: string
  title: string
  addressInputRef: RefObject<HTMLInputElement | null>
  uploadControl?: ReactNode
  children?: ReactNode
  onChangeAddress: (value: string) => void
  onChangeTitle: (value: string) => void
  onSave: () => void
  onCancel: () => void
}) {
  const label = useEditorLabel()
  const errorId = `${formId}-error`

  return (
    <form
      className={compact ? 'resource-form resource-form-compact' : 'resource-form'}
      onKeyDown={event => {
        if (composingKey(event.nativeEvent)) {
          if (event.key === 'Enter') event.preventDefault()
          return
        }
        if (event.key === 'Escape' && !busy) {
          event.preventDefault()
          onCancel()
        }
      }}
      onSubmit={event => {
        event.preventDefault()
        onSave()
      }}>
      {compact ? (
        <div className="resource-form-row">
          {uploadControl}
          <Input
            ref={addressInputRef}
            aria-label={label('resource_address')}
            value={address}
            placeholder={label('link_placeholder')}
            autoCorrect="off"
            autoCapitalize="off"
            spellCheck={false}
            aria-invalid={Boolean(error)}
            aria-describedby={error ? errorId : undefined}
            disabled={busy}
            onChange={event => onChangeAddress(event.target.value)}
          />
          <Button type="submit" size="xs" disabled={busy}>
            {label('resource_apply')}
          </Button>
          <Button type="button" size="xs" variant="ghost" disabled={busy} onClick={onCancel}>
            {label('resource_cancel')}
          </Button>
        </div>
      ) : (
        <>
          <strong>{label(titleKey)}</strong>
          {uploadControl}
          <label htmlFor={`${formId}-address`}>
            {label('resource_address')}
            <Input
              id={`${formId}-address`}
              ref={addressInputRef}
              value={address}
              placeholder={label('link_placeholder')}
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              aria-invalid={Boolean(error)}
              aria-describedby={error ? errorId : undefined}
              disabled={busy}
              onChange={event => onChangeAddress(event.target.value)}
            />
          </label>
          <label htmlFor={`${formId}-title`}>
            {label('resource_title')}
            <Input
              id={`${formId}-title`}
              value={title}
              disabled={busy}
              onChange={event => onChangeTitle(event.target.value)}
            />
          </label>
          {children}
        </>
      )}
      {error && (
        <p id={errorId} role="alert" className="resource-form-error">
          {error}
        </p>
      )}
      {!compact && (
        <div className="resource-actions">
          <Button type="submit" size="sm" disabled={busy}>
            {label('resource_apply')}
          </Button>
          <Button type="button" size="sm" variant="ghost" disabled={busy} onClick={onCancel}>
            {label('resource_cancel')}
          </Button>
        </div>
      )}
    </form>
  )
}
