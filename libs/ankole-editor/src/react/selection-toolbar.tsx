import { composingKey } from '@ankole/uikit/lib/keyboard'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Command } from '../core/command'
import { Node, type Leaf, type Mark, type Plot } from '../core/doc'
import type { Wordgard } from '../core/editor'
import browser from '../core/editor/browser'
import { GardSelection, type GardState } from '../core/state'
import { webURL, type ResourceView } from '../document/resources'
import { singleSelectedInlineMathPos } from '../blocks/math'
import { toggleFormat, type FormatName } from '../editor/commands'
import { editorHost, openLinkHref, type EditorHost } from '../editor/host-context'
import { commentSelection } from '../editor/comments'
import {
  availableLinkViews,
  convertInlineLinkView,
  convertPageMentionToEmbed,
  inlineLinkView,
  trackInlineLink,
  trackTextRange
} from '../editor/link-views'
import {
  linkAt,
  linkAtPos,
  removeLink,
  removeLinkAt,
  setLink,
  singleLinkInRange,
  updateLinkAt,
  type LinkInfo
} from '../editor/links'
import { Mention, formats, safeLinkHref, type MentionTarget } from '../editor/schema'
import { useEditor, useEditorLabel, useEditorState } from './context'
import { isKnowledge } from '../editor/knowledge'
import {
  LinkEditForm,
  LinkFloatingBar,
  MentionFloatingBar,
  rovingToolbarKeyDown,
  type LinkBarDescription,
  type LinkEditError
} from './link-view-menu'
import {
  SELECTION_FORMAT_BUTTONS,
  SelectionActions,
  type PageMentionInfo,
  type SelectionToolbarInfo
} from './selection-actions'

/** The address for the link form input, or null when it is not a usable address (SPEC §7.6). */
export function resolveLinkInputUrl(value: string, host?: EditorHost): string | null {
  const url = value.trim()
  if (!url) return null
  const pageId =
    host?.matchPageUrl?.(url) ??
    (/^[^\s/:@]+\.[a-z\d-]{2,}(?:[:/?#].*)?$/i.test(url) ? host?.matchPageUrl?.(`https://${url}`) : null)
  if (pageId) return `ankole:page/${pageId}`
  if (url.startsWith('/') || url.startsWith('#') || url.startsWith('ankole:page/') || url.startsWith('ankole:asset/')) {
    return safeLinkHref(url)
  }
  if (/^(?:mailto:|tel:)/i.test(url)) {
    return /\s/.test(url) ? null : safeLinkHref(url)
  }
  if (/^https?:\/\//i.test(url)) {
    return webURL(url) ? safeLinkHref(url) : null
  }
  if (/^[a-z][a-z\d+.-]*:/i.test(url)) return null
  if (/^[^\s@/:]+@[^\s@/:]+\.[^\s@/:]+$/.test(url)) {
    return safeLinkHref(`mailto:${url}`)
  }
  if (/^[^\s/:@]+\.[a-z\d-]{2,}(?:[:/?#].*)?$/i.test(url)) {
    const candidate = `https://${url}`
    return webURL(candidate) ? safeLinkHref(candidate) : null
  }
  return null
}

function describeLinkForBar(host: EditorHost | undefined, href: string): LinkBarDescription {
  if (href.startsWith('ankole:page/')) {
    const pageId = href.slice('ankole:page/'.length)
    const described = host?.describePageLink?.(pageId)
    if (described) {
      const display = described.title?.trim() || described.href
      return { display, title: described.href, editHref: described.href }
    }
  }
  return { display: href, title: href, editHref: href }
}

function caretPageMention(state: GardState): PageMentionInfo | null {
  if (!(state.selection instanceof GardSelection.Text) || !state.selection.empty) return null
  const head = state.sel.head
  if (head.inText) return null
  const block = head.parent
  if (!block.node.inlineContent) return null
  for (const index of [head.index - 1, head.index]) {
    const leaf = block.node.content[index]
    if (leaf?.type !== Mention) continue
    const target = (leaf as Leaf<MentionTarget>).param
    if (!('page' in target)) continue
    let from = block.start
    for (let i = 0; i < index; i++) from += block.node.content[i]!.length
    return { id: target.page, from, to: from + leaf.length }
  }
  return null
}

/** Whether every inline node in the range that can carry the format has it. */
function hasFormat(doc: Plot.Doc, from: number, to: number, mark: Mark) {
  let found = false,
    missing = false
  doc.iterate(from, to, node => {
    if (missing) return false
    if (node.isLeaf && node.isInline && doc.schema.markAllowed(mark.type, node.type)) {
      if (mark.isInSet(node.marks)) found = true
      else missing = true
    }
  })
  return found && !missing
}

type Range = { from: number; to: number }

function isPlainTextRange(doc: Plot.Doc, { from, to }: Range): boolean {
  if (from >= to) return false
  let allText = true
  doc.iterate(from, to, node => {
    if (node.isLeaf && !node.isText) {
      allText = false
      return false
    }
  })
  return allText
}

/** The selected range that the toolbar formats: non-blank text outside code blocks. */
function formattable(state: GardState): Range | null {
  const { selection, doc } = state
  if (!(selection instanceof GardSelection.Text) || selection.empty) return null
  const { from, to } = selection
  if (
    singleSelectedInlineMathPos(state) === null &&
    !doc.textContent({ from, to, leafText: leaf => (leaf.type === Mention ? '@' : '') }).trim()
  ) {
    return null
  }
  let code = false
  doc.iterate(from, to, node => {
    if (node.type.hasRole(Node.Role.Code)) code = true
    return !code
  })
  return code ? null : { from, to }
}

/** The part of the viewport that shows editor content: inside scrolling ancestors, below the editor toolbar. */
function visibleArea(editor: Wordgard) {
  let top = 0,
    bottom = window.innerHeight
  for (let element = editor.dom.parentElement; element && element !== document.body; element = element.parentElement) {
    if (getComputedStyle(element).overflowY === 'visible') continue
    const rect = element.getBoundingClientRect()
    top = Math.max(top, rect.top)
    bottom = Math.min(bottom, rect.bottom)
  }
  const toolbar = editor.dom.closest('.ankole-editor')?.querySelector('.editor-toolbar')
  if (toolbar) top = Math.max(top, toolbar.getBoundingClientRect().bottom)
  return { top, bottom }
}

/** The rectangle of the selection: the DOM range that the editor shows, or the document positions. */
function selectionRect(editor: Wordgard, { from, to }: Range) {
  const dom = window.getSelection()
  if (
    dom?.rangeCount &&
    !dom.isCollapsed &&
    editor.contentDOM.contains(dom.anchorNode) &&
    editor.contentDOM.contains(dom.focusNode)
  ) {
    return dom.getRangeAt(0).getBoundingClientRect()
  }
  const start = editor.coordsAtPos(from, 1),
    end = editor.coordsAtPos(to, -1)
  const left = Math.min(start.left, end.left),
    top = Math.min(start.top, end.top)
  return new DOMRect(left, top, Math.max(start.right, end.right) - left, Math.max(start.bottom, end.bottom) - top)
}

/** Whether the host acts on any selection, editable or not: asking an Agent about it or commenting on it. */
const actsOnSelection = (editor: Wordgard) => {
  const host = editorHost(editor)
  return !!((!isKnowledge(editor.state) && host?.requestComment) || host?.askAgent)
}

function sameRect(a: DOMRect, b: DOMRect): boolean {
  return (
    Math.abs(a.left - b.left) < 0.5 &&
    Math.abs(a.top - b.top) < 0.5 &&
    Math.abs(a.width - b.width) < 0.5 &&
    Math.abs(a.height - b.height) < 0.5
  )
}

/** The open link form, with the link that it edits, if any. */
type LinkForm = { link: LinkInfo | null; canEditText: boolean; initialText: string }

type TrackedTarget =
  | { kind: 'link'; tracker: ReturnType<typeof trackInlineLink> }
  | { kind: 'range'; tracker: ReturnType<typeof trackTextRange> }

export function SelectionToolbar() {
  const label = useEditorLabel()
  const editor = useEditor()
  const state = useEditorState()
  const host = editorHost(editor)
  const toolbar = useRef<HTMLDivElement>(null)
  const [info, setInfo] = useState<SelectionToolbarInfo | null>(null)
  const [linkForm, setLinkForm] = useState<LinkForm | null>(null)
  const [url, setUrl] = useState('')
  const [linkText, setLinkText] = useState('')
  const [error, setError] = useState<LinkEditError>(null)
  const trackedTarget = useRef<TrackedTarget | null>(null)
  const releaseTrackedTarget = () => {
    trackedTarget.current?.tracker.finish()
    trackedTarget.current = null
  }
  useEffect(() => releaseTrackedTarget, [editor])
  useLayoutEffect(() => {
    if (!linkForm) releaseTrackedTarget()
  }, [linkForm])
  const [unfurling, setUnfurling] = useState(false)
  const [, setPageVersion] = useState(0)
  const [position, setPosition] = useState({ left: 0, top: 0 })
  const form = useRef<LinkForm | null>(null)
  form.current = linkForm
  // The selection that Escape hid the toolbar for. Another selection shows it again.
  const dismissed = useRef<GardSelection | null>(null)
  // The state that Ask Agent or comment handed off. Any later state shows the toolbar again.
  const handedOff = useRef<GardState | null>(null)
  // Portaled menus render outside the toolbar; the toolbar holds its place while focus or interaction is in them.
  const typeMenu = useRef<HTMLDivElement>(null)
  const viewMenu = useRef<HTMLDivElement>(null)
  const viewMenuOpen = useRef(false)
  const hovered = useRef<{ link: LinkInfo; anchor: HTMLAnchorElement } | null>(null)
  const pendingHoverAnchor = useRef<HTMLAnchorElement | null>(null)
  const hoverTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const embeddableCache = useRef(new Map<string, boolean>())
  const pendingEmbeddable = useRef(new Set<string>())
  const refresh = useRef(() => {})

  const clearHoverTimer = () => {
    pendingHoverAnchor.current = null
    if (hoverTimer.current !== null) {
      clearTimeout(hoverTimer.current)
      hoverTimer.current = null
    }
  }

  const scheduleClearHover = () => {
    clearHoverTimer()
    hoverTimer.current = setTimeout(() => {
      hoverTimer.current = null
      if (viewMenuOpen.current || form.current) return
      if (hovered.current) {
        hovered.current = null
        refresh.current()
      }
    }, 180)
  }

  // ⌘K and the link button: edit the selected text, the link at the caret, or a hovered link.
  const openLink = (explicitLink?: LinkInfo) => {
    const { state } = editor
    if (state.readOnly) return false
    const range = explicitLink ? null : formattable(state)
    const link = explicitLink ?? linkAt(state)
    const target = explicitLink ?? range ?? (state.selection.empty ? link : null)
    if (!target) return false
    clearHoverTimer()
    const canEditText = Boolean(link && isPlainTextRange(state.doc, link))
    const initialText = link && canEditText ? state.doc.textContent({ from: link.from, to: link.to }) : ''
    const currentHost = editorHost(editor)
    releaseTrackedTarget()
    trackedTarget.current = link
      ? { kind: 'link', tracker: trackInlineLink(editor, link, link.href) }
      : range
        ? { kind: 'range', tracker: trackTextRange(editor, range) }
        : null
    setLinkForm({ link, canEditText, initialText })
    setUrl(link ? describeLinkForBar(currentHost, link.href).editHref : '')
    setLinkText(initialText)
    setError(null)
    setInfo(
      current =>
        current ?? {
          rect: selectionRect(editor, target),
          active: [],
          link: !!link,
          selectedLink: range ? singleLinkInRange(state, range) : null,
          caretLink: range ? null : link,
          caretMention: null
        }
    )
    return true
  }

  const closeLink = () => {
    releaseTrackedTarget()
    setLinkForm(null)
    setError(null)
    editor.focus()
  }

  useEffect(() => {
    return host?.subscribePageLinks?.(() => {
      setPageVersion(version => version + 1)
      refresh.current()
    })
  }, [host])

  useEffect(() => {
    let frame = 0,
      pointer = false,
      composing = false
    const update = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        const focused = document.activeElement === editor.contentDOM
        const inToolbar = [toolbar.current, typeMenu.current, viewMenu.current].some(part =>
          part?.contains(document.activeElement)
        )
        if (form.current && (inToolbar || focused)) {
          const live = trackedTarget.current?.tracker.current()
          if (!live) {
            setError('changed')
            return
          }
          const rect = selectionRect(editor, live)
          setInfo(current => (current && !sameRect(current.rect, rect) ? { ...current, rect } : current))
          return
        }
        // The toolbar keeps its place while the user works in it or an open portaled menu.
        if (viewMenuOpen.current || inToolbar) {
          return
        }
        const { state } = editor
        if (dismissed.current && !dismissed.current.eq(state.selection)) dismissed.current = null
        const range = formattable(state) ?? (actsOnSelection(editor) ? commentSelection(editor) : null)
        if (state.readOnly && !actsOnSelection(editor)) {
          setInfo(null)
          return
        }

        if (range) {
          hovered.current = null
          if (
            !focused ||
            pointer ||
            composing ||
            editor.composing ||
            dismissed.current?.eq(state.selection) ||
            handedOff.current === state
          ) {
            setInfo(null)
            setLinkForm(null)
            return
          }
          dismissed.current = null
          const rect = selectionRect(editor, range)
          const area = visibleArea(editor)
          if ((!rect.width && !rect.height) || rect.bottom < area.top || rect.top > area.bottom) {
            setInfo(null)
            return
          }
          setInfo({
            rect,
            active: SELECTION_FORMAT_BUTTONS.map(({ format }) =>
              hasFormat(state.doc, range.from, range.to, formats[format])
            ),
            link: !!linkAt(state),
            selectedLink: !state.readOnly ? singleLinkInRange(state, range) : null,
            caretLink: null,
            caretMention: null
          })
          return
        }

        const caretLink =
          state.selection.empty && !state.readOnly && focused && !dismissed.current?.eq(state.selection)
            ? linkAt(state)
            : null

        let hoveredLink: LinkInfo | null = null
        let hoveredRect: DOMRect | null = null
        if (!caretLink && !state.readOnly && hovered.current) {
          const { anchor } = hovered.current
          if (anchor.isConnected && editor.contentDOM.contains(anchor)) {
            const pos = editor.posAtDOM(anchor, 0)
            const fresh = linkAtPos(state, pos)
            if (fresh) {
              hovered.current = { link: fresh, anchor }
              hoveredLink = fresh
              hoveredRect = anchor.getBoundingClientRect()
            } else {
              hovered.current = null
            }
          } else {
            hovered.current = null
          }
        }

        const activeLink = caretLink ?? hoveredLink
        if (activeLink && !pointer && !composing && !editor.composing && handedOff.current !== state) {
          const rect = hoveredRect ?? selectionRect(editor, activeLink)
          const area = visibleArea(editor)
          if ((!rect.width && !rect.height) || rect.bottom < area.top || rect.top > area.bottom) {
            setInfo(null)
            return
          }
          setInfo({
            rect,
            active: [],
            link: true,
            selectedLink: null,
            caretLink: activeLink,
            caretMention: null
          })
          return
        }

        const currentHost = editorHost(editor)
        const mention =
          state.selection.empty &&
          !state.readOnly &&
          !isKnowledge(state) &&
          focused &&
          !pointer &&
          !composing &&
          !editor.composing &&
          !dismissed.current?.eq(state.selection) &&
          handedOff.current !== state
            ? caretPageMention(state)
            : null
        let canEmbedMention = false
        if (mention && currentHost?.canEmbedPage) {
          const decision = currentHost.canEmbedPage(mention.id)
          if (typeof decision === 'boolean') {
            embeddableCache.current.set(mention.id, decision)
            canEmbedMention = decision
          } else if (embeddableCache.current.has(mention.id)) {
            canEmbedMention = embeddableCache.current.get(mention.id)!
          } else if (!pendingEmbeddable.current.has(mention.id)) {
            pendingEmbeddable.current.add(mention.id)
            void decision
              .then(
                allowed => {
                  embeddableCache.current.set(mention.id, allowed)
                  if (allowed) refresh.current()
                },
                () => {
                  embeddableCache.current.set(mention.id, false)
                }
              )
              .finally(() => {
                pendingEmbeddable.current.delete(mention.id)
              })
          }
        }
        if (mention && canEmbedMention) {
          const mentionDom = editor.nodeDOM(mention.from)
          const rect = mentionDom ? mentionDom.getBoundingClientRect() : selectionRect(editor, mention)
          const area = visibleArea(editor)
          if ((!rect.width && !rect.height) || rect.bottom < area.top || rect.top > area.bottom) {
            setInfo(null)
            return
          }
          setInfo({
            rect,
            active: [],
            link: false,
            selectedLink: null,
            caretLink: null,
            caretMention: mention
          })
          return
        }

        setInfo(null)
        if (!form.current) setLinkForm(null)
      })
    }
    refresh.current = update
    const content = editor.contentDOM
    const pointerDown = () => {
      pointer = true
      clearHoverTimer()
      hovered.current = null
      update()
    }
    const pointerUp = () => {
      pointer = false
      update()
    }
    const pointerOver = (event: PointerEvent) => {
      if (pointer || editor.state.readOnly) return
      const target = event.target instanceof Element ? event.target : null
      const anchor = target?.closest('a[href]') as HTMLAnchorElement | null
      if (anchor && content.contains(anchor) && !anchor.closest('.editor-mention, [contenteditable="false"]')) {
        if (hovered.current?.anchor === anchor) {
          clearHoverTimer()
          return
        }
        if (pendingHoverAnchor.current === anchor) return
        clearHoverTimer()
        pendingHoverAnchor.current = anchor
        hoverTimer.current = setTimeout(() => {
          hoverTimer.current = null
          pendingHoverAnchor.current = null
          if (pointer || editor.state.readOnly || !anchor.isConnected) return
          const pos = editor.posAtDOM(anchor, 0)
          const found = linkAtPos(editor.state, pos)
          if (found) {
            hovered.current = { link: found, anchor }
            update()
          }
        }, 120)
      } else {
        if (pendingHoverAnchor.current) clearHoverTimer()
        if (hovered.current) scheduleClearHover()
      }
    }
    const pointerLeave = () => {
      if (pendingHoverAnchor.current) clearHoverTimer()
      if (hovered.current) scheduleClearHover()
    }
    const compositionStart = () => {
      composing = true
      hovered.current = null
      setLinkForm(null)
      update()
    }
    const compositionEnd = () => {
      composing = false
      update()
    }
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented || composingKey(event) || editor.composing) return
      // ⌘K on Apple platforms, where Ctrl+K deletes to the end of the line; Ctrl+K elsewhere.
      const mod = browser.mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey
      if (event.key === 'Escape') {
        clearHoverTimer()
        const hadHover = hovered.current !== null
        hovered.current = null
        if (
          hadHover ||
          commentSelection(editor) ||
          (editor.state.selection.empty && (linkAt(editor.state) || caretPageMention(editor.state)))
        ) {
          dismissed.current = editor.state.selection
          update()
        }
      } else if (event.altKey && event.key === 'F10') {
        const button = toolbar.current?.querySelector('button')
        if (button) {
          event.preventDefault()
          button.focus()
        }
      } else if (mod && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'k') {
        if (openLink()) event.preventDefault()
      }
    }
    document.addEventListener('focusin', update)
    document.addEventListener('focusout', update)
    document.addEventListener('pointerup', pointerUp)
    content.addEventListener('pointerdown', pointerDown)
    content.addEventListener('pointerover', pointerOver)
    content.addEventListener('pointerleave', pointerLeave)
    content.addEventListener('compositionstart', compositionStart)
    content.addEventListener('compositionend', compositionEnd)
    content.addEventListener('keydown', key)
    window.addEventListener('scroll', update, true)
    window.addEventListener('resize', update)
    window.visualViewport?.addEventListener('resize', update)
    window.visualViewport?.addEventListener('scroll', update)
    return () => {
      cancelAnimationFrame(frame)
      clearHoverTimer()
      viewMenuOpen.current = false
      refresh.current = () => {}
      document.removeEventListener('focusin', update)
      document.removeEventListener('focusout', update)
      document.removeEventListener('pointerup', pointerUp)
      content.removeEventListener('pointerdown', pointerDown)
      content.removeEventListener('pointerover', pointerOver)
      content.removeEventListener('pointerleave', pointerLeave)
      content.removeEventListener('compositionstart', compositionStart)
      content.removeEventListener('compositionend', compositionEnd)
      content.removeEventListener('keydown', key)
      window.removeEventListener('scroll', update, true)
      window.removeEventListener('resize', update)
      window.visualViewport?.removeEventListener('resize', update)
      window.visualViewport?.removeEventListener('scroll', update)
    }
    // `openLink` reads only the editor and state setters, which do not change.
  }, [editor])

  // Each editor update can change the selection, its formats or its place.
  useEffect(() => refresh.current(), [state])

  useLayoutEffect(() => {
    if (!info || !toolbar.current) return
    const { width, height } = toolbar.current.getBoundingClientRect()
    const viewport = window.visualViewport
    const minX = (viewport?.offsetLeft ?? 0) + 8
    const maxX = minX + (viewport?.width ?? window.innerWidth) - 16
    const minY = Math.max(viewport?.offsetTop ?? 0, visibleArea(editor).top) + 8
    const maxY = (viewport?.offsetTop ?? 0) + (viewport?.height ?? window.innerHeight) - 8
    const { rect } = info
    setPosition({
      left: Math.max(minX, Math.min(rect.left + rect.width / 2 - width / 2, maxX - width)),
      top: rect.top - height - 8 >= minY ? rect.top - height - 8 : Math.min(rect.bottom + 8, maxY - height)
    })
  }, [editor, info, linkForm, error])

  const apply = (format: FormatName) => {
    toggleFormat(editor, format)
    editor.focus()
  }

  const submitLink = () => {
    if (error === 'changed') return
    if (linkForm?.link && linkForm.canEditText && linkText !== linkForm.initialText && !linkText.trim()) {
      setError('empty_text')
      return
    }
    const href = resolveLinkInputUrl(url, editorHost(editor))
    if (!href) {
      setError('invalid_url')
      return
    }
    if (linkForm?.link) {
      const target = trackedTarget.current?.kind === 'link' ? trackedTarget.current.tracker.finish() : null
      trackedTarget.current = null
      if (!target) {
        setError('changed')
        return
      }
      if (linkForm.canEditText && linkText !== linkForm.initialText) {
        updateLinkAt(editor, target, { href, text: linkText })
      } else {
        updateLinkAt(editor, target, { href })
      }
    } else {
      const live = trackedTarget.current?.kind === 'range' ? trackedTarget.current.tracker.finish() : null
      trackedTarget.current = null
      if (!live) {
        setError('changed')
        return
      }
      if (editor.state.selection.from !== live.from || editor.state.selection.to !== live.to) {
        editor.dispatch({ selection: GardSelection.range(live.from, live.to) })
      }
      Command.dispatch(editor, setLink, { href })
    }
    hovered.current = null
    closeLink()
  }

  const switchInlineView = async (target: LinkInfo, nextView: ResourceView) => {
    clearHoverTimer()
    hovered.current = null
    viewMenuOpen.current = false
    if (nextView === 'title') setUnfurling(true)
    try {
      await convertInlineLinkView(editor, target, nextView)
    } finally {
      setUnfurling(false)
      refresh.current()
    }
  }

  if (!info) {
    viewMenuOpen.current = false
    return null
  }
  const activeInlineView =
    info.caretLink && info.caretLink.to <= state.doc.length ? inlineLinkView(state, info.caretLink) : 'link'
  const linkViews = availableLinkViews(state)
  const caretLinkDisplay = info.caretLink ? describeLinkForBar(host, info.caretLink.href) : null
  const caretMentionDisplay = info.caretMention ? describeLinkForBar(host, `ankole:page/${info.caretMention.id}`) : null

  return createPortal(
    <div
      ref={toolbar}
      className="selection-toolbar ankole-editor-overlay ceramic"
      style={position}
      role={linkForm ? 'dialog' : 'toolbar'}
      data-mention-toolbar={info.caretMention?.id}
      aria-label={label(linkForm ? 'edit_link' : info.caretLink || info.caretMention ? 'link' : 'selection_format')}
      onPointerEnter={clearHoverTimer}
      onPointerLeave={() => {
        if (hovered.current && !viewMenuOpen.current && !form.current) scheduleClearHover()
      }}
      onKeyDown={event => {
        // React bubbles keys from the portaled menus through here; those menus handle their own keys.
        if (
          composingKey(event.nativeEvent) ||
          (event.target instanceof Element && !event.currentTarget.contains(event.target))
        ) {
          return
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          event.stopPropagation()
          hovered.current = null
          if (linkForm) closeLink()
          else {
            dismissed.current = editor.state.selection
            setInfo(null)
            editor.focus()
          }
        } else if (!linkForm) {
          rovingToolbarKeyDown(event, 'button')
        }
      }}>
      {linkForm ? (
        <LinkEditForm
          canEditText={linkForm.canEditText}
          hasExistingLink={Boolean(linkForm.link)}
          linkText={linkText}
          url={url}
          error={error}
          onChangeText={value => {
            setLinkText(value)
            setError(current => (current === 'changed' ? 'changed' : null))
          }}
          onChangeUrl={value => {
            setUrl(value)
            setError(current => (current === 'changed' ? 'changed' : null))
          }}
          onSubmit={submitLink}
          onCancel={closeLink}
          onRemove={() => {
            if (error === 'changed') return
            if (linkForm.link) {
              const target = trackedTarget.current?.kind === 'link' ? trackedTarget.current.tracker.finish() : null
              trackedTarget.current = null
              if (!target) {
                setError('changed')
                return
              }
              removeLinkAt(editor, target)
            } else Command.dispatch(editor, removeLink)
            hovered.current = null
            closeLink()
          }}
        />
      ) : info.caretLink && caretLinkDisplay ? (
        <LinkFloatingBar
          editor={editor}
          link={info.caretLink}
          display={caretLinkDisplay}
          activeView={activeInlineView}
          views={linkViews}
          unfurling={unfurling}
          menuRef={viewMenu}
          onOpenLink={() => openLinkHref(editor, info.caretLink!.href)}
          onEditLink={() => void openLink(info.caretLink!)}
          onRemoveLink={() => {
            const target = info.caretLink!
            hovered.current = null
            removeLinkAt(editor, target)
            setInfo(null)
            editor.focus()
          }}
          onSwitchView={viewOption => void switchInlineView(info.caretLink!, viewOption)}
          onMenuOpenChange={open => {
            viewMenuOpen.current = open
            if (open) clearHoverTimer()
            else refresh.current()
          }}
          onMenuPointerEnter={clearHoverTimer}
          onMenuPointerLeave={() => {
            if (hovered.current && !viewMenuOpen.current) scheduleClearHover()
          }}
        />
      ) : info.caretMention && caretMentionDisplay ? (
        <MentionFloatingBar
          editor={editor}
          display={caretMentionDisplay}
          canOpenPage={Boolean(host?.openPage)}
          menuRef={viewMenu}
          onOpenPage={() => host?.openPage?.(info.caretMention!.id)}
          onEmbed={() => {
            const target = info.caretMention!
            setInfo(null)
            convertPageMentionToEmbed(editor, target, target.id)
          }}
          onMenuOpenChange={open => {
            viewMenuOpen.current = open
            if (!open) refresh.current()
          }}
        />
      ) : (
        <SelectionActions
          editable={!state.readOnly && !!formattable(state)}
          info={info}
          apply={apply}
          openLink={() => openLink()}
          switchInlineView={switchInlineView}
          unfurling={unfurling}
          hide={() => {
            handedOff.current = editor.state
            setInfo(null)
          }}
          typeMenu={typeMenu}
          viewMenu={viewMenu}
          onViewMenuOpenChange={open => {
            viewMenuOpen.current = open
            if (!open) refresh.current()
          }}
        />
      )}
    </div>,
    document.body
  )
}
