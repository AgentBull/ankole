import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Button, Input, DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem } from '@ankole/uikit'
import { composingKey } from '@ankole/uikit/lib/keyboard'
import { RiArrowDownSLine, RiCheckLine, RiExternalLinkLine, RiLink } from '@remixicon/react'
import { Embed, EmbedHref, EmbedTitle, embedAttributes } from '../blocks/embed'
import {
  closeResourceEditor,
  resourceBlocks,
  resourceAttributes,
  resourceChanges,
  resourceEditorField,
  resourceEditorOpenKey,
  type ResourceAttributes,
  type ResourceKind
} from '../blocks/resources'
import {
  assetURL,
  iframeURL,
  mediaKind,
  replaceResourceSource,
  videoEmbedURL,
  webURL,
  type ResourceView
} from '../document/resources'
import { dispatchStep } from '../editor/block-insert'
import { BlockSelection } from '../editor/block-selection'
import { unitAt } from '../editor/block-target'
import type { EditorHost } from '../editor/host-context'
import { useEditor, useEditorLabel, useEditorState } from './context'
import { isKnowledge } from '../editor/knowledge'

type Kind = ResourceKind | 'embed'
const containerIDs = new WeakMap<Element, number>()
let nextID = 0

function resourceHostname(src: string): string {
  try {
    return new URL(src, typeof window === 'undefined' ? 'http://localhost' : window.location.href).hostname
  } catch {
    return src
  }
}

function isSameOriginFrame(frameSrc: string): boolean {
  if (typeof window === 'undefined') return false
  try {
    return new URL(frameSrc, window.location.href).origin === window.location.origin
  } catch {
    return true
  }
}

/** React owns controls inside atomic nodes; the editor owns positions, selection and persistence. */
export function ResourceBlocks({ host }: { host?: EditorHost }) {
  const editor = useEditor()
  const state = useEditorState()
  const [portals, setPortals] = useState<ReactNode[]>([])
  // nodeDOM flushes pending editor updates, so synchronize portals after React renders.
  useLayoutEffect(() => {
    const activePos = state.field(resourceEditorField, false) ?? null
    const openKey = state.field(resourceEditorOpenKey, false) ?? 0
    const portals: ReactNode[] = []
    state.doc.iterate((node, pos) => {
      const kind =
        node.type === Embed.type && node.mark(EmbedHref) !== undefined
          ? 'embed'
          : (resourceBlocks.find(block => block.type === node.type)?.name as ResourceKind | undefined)
      if (!kind) return
      const dom = editor.nodeDOM(pos)
      const container = dom?.matches('.editor-resource') ? dom : dom?.querySelector('.editor-resource')
      if (!container) return false
      if (!containerIDs.has(container)) containerIDs.set(container, ++nextID)
      const attrs =
        kind === 'embed'
          ? { src: embedAttributes(node).href, title: embedAttributes(node).title }
          : resourceAttributes(node)
      portals.push(
        createPortal(
          <ResourceBlock
            kind={kind}
            attrs={attrs}
            container={container}
            host={host}
            openKey={activePos === pos ? openKey : 0}
          />,
          container,
          String(containerIDs.get(container))
        )
      )
      return false
    })
    setPortals(portals)
  }, [editor, state, host])
  return portals
}

export function ResourceBlock({
  kind,
  attrs,
  container,
  host,
  openKey = 0
}: {
  kind: Kind
  attrs: ResourceAttributes
  container: Element
  host?: EditorHost
  openKey?: number
}) {
  const editor = useEditor()
  const label = useEditorLabel()
  const readOnly = useEditorState(state => state.readOnly)
  const knowledge = useEditorState(isKnowledge)
  const [editing, setEditing] = useState(!attrs.src)
  const [edits, setEdits] = useState<ResourceAttributes>({})
  const draft = { ...attrs, ...edits }
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const input = useRef<HTMLInputElement>(null)
  const addressInput = useRef<HTMLInputElement>(null)
  const lastOpenKey = useRef(0)
  const pendingFocus = useRef(false)
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
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
    setEdits({})
    setError('')
    setEditing(true)
  }, [openKey, readOnly])
  useLayoutEffect(() => {
    if (!pendingFocus.current || !editing || readOnly) return
    const frame = requestAnimationFrame(() => {
      pendingFocus.current = false
      addressInput.current?.focus()
      addressInput.current?.select()
    })
    return () => cancelAnimationFrame(frame)
  }, [openKey, editing, readOnly])
  const view = attrs.view ?? (kind === 'media' || kind === 'embed' ? 'preview' : 'card')
  const src = attrs.src ? assetURL(attrs.src, host?.resolveAsset) : null
  const title = attrs.title || (attrs.src ? attrs.src.split('/').at(-1) || attrs.src : label(`${kind}_title`))
  const resolvedKind = mediaKind(attrs)

  const update = (next: ResourceAttributes): boolean => {
    if (editor.state.readOnly || !container.isConnected) return false
    const target = editor.nodeFromDOM(container)
    if (!target) return false
    const { pos, node: current } = target
    if (
      !current ||
      (kind === 'embed'
        ? current.type !== Embed.type
        : !resourceBlocks.some(block => block.name === kind && block.type === current.type))
    ) {
      return false
    }
    if (kind === 'embed') {
      dispatchStep(editor, {
        changes: [
          ...('src' in next ? [{ from: pos, add: EmbedHref.of(next.src ?? '') }] : []),
          ...('title' in next ? [{ from: pos, add: EmbedTitle.of(next.title ?? '') }] : [])
        ],
        userEvent: 'embed.configure'
      })
    } else {
      dispatchStep(editor, {
        changes: resourceChanges(current, pos, next),
        userEvent: 'resource.configure'
      })
    }
    return true
  }
  const finishEditing = (selectBlock: boolean) => {
    setError('')
    setEdits({})
    setEditing(false)
    if (!container.isConnected) return
    const target = editor.nodeFromDOM(container)
    const unit = selectBlock && target ? unitAt(editor.state.doc, target.pos, 1) : null
    const selected = unit && BlockSelection.between(editor.state.doc, unit.before, unit.before)
    const hasOpen = (editor.state.field(resourceEditorField, false) ?? null) !== null
    if (hasOpen || selected) {
      editor.dispatch({
        ...(hasOpen ? { effects: closeResourceEditor.of(null) } : {}),
        ...(selected ? { selection: selected, userEvent: 'select.block' } : {})
      })
    }
    editor.focus()
  }
  const save = () => {
    const hadSource = Boolean(attrs.src)
    const address = draft.src?.trim() ?? ''
    // Host addresses may be kept while editing a caption, but cannot be entered as external URLs.
    const valid = address.startsWith('ankole:asset/') && address === attrs.src ? address : webURL(address)
    if (!valid) {
      setError(label('resource_invalid'))
      return
    }
    if (draft.image && !webURL(draft.image)) {
      setError(label('resource_invalid'))
      return
    }
    if (update({ ...edits, ...('src' in edits ? { src: valid } : {}) })) {
      finishEditing(hadSource)
    }
  }
  const upload = async (file: File) => {
    if (!host?.uploadAsset || busy) return
    if (!(knowledge ? /^image\// : /^(image|video)\//).test(file.type)) {
      setError(label('resource_media_invalid'))
      return
    }
    const hadSource = Boolean(attrs.src)
    setBusy(true)
    setError('')
    try {
      const uploaded = await host.uploadAsset(file)
      if (!alive.current) return
      const next = {
        ...replaceResourceSource(uploaded),
        title: uploaded.title ?? file.name
      }
      if (update(next)) {
        finishEditing(hadSource)
      }
    } catch (reason) {
      if (alive.current) setError(reason instanceof Error ? reason.message : label('resource_upload_failed'))
    } finally {
      if (alive.current) setBusy(false)
    }
  }

  let preview: ReactNode = null
  if (src && view === 'preview') {
    const video = videoEmbedURL(src)
    if (kind === 'embed' || kind === 'bookmark' || (resolvedKind === 'video' && video)) {
      const frameSrc = iframeURL(src)
      if (frameSrc) {
        const sameOrigin = isSameOriginFrame(frameSrc)
        preview = (
          <>
            <iframe
              className="resource-frame"
              src={frameSrc}
              title={title}
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
            <p className="resource-hint">{label('resource_embed_hint')}</p>
          </>
        )
      }
    } else if (resolvedKind === 'image') {
      preview = <img className="resource-media" src={src} alt={attrs.title ?? ''} loading="lazy" />
    } else {
      preview = <video className="resource-media" src={src} controls playsInline preload="metadata" />
    }
  }

  const views: ResourceView[] = kind === 'bookmark' ? ['link', 'title', 'card', 'preview'] : ['link', 'card', 'preview']
  return (
    <div
      className="resource-block"
      data-kind={kind}
      data-view={view}
      onMouseDown={event => event.stopPropagation()}
      onClick={event => {
        event.stopPropagation()
        if (editing || readOnly || !container.isConnected) return
        const target = event.target instanceof Element ? event.target : null
        if (target?.closest('a, button, input, iframe, video, [role="menuitem"]')) return
        const found = editor.nodeFromDOM(container)
        const unit = found && unitAt(editor.state.doc, found.pos, 1)
        const selected = unit && BlockSelection.between(editor.state.doc, unit.before, unit.before)
        if (selected) {
          editor.dispatch({ selection: selected, userEvent: 'select.block' })
          editor.focus()
        }
      }}
      onKeyDown={event => event.stopPropagation()}
      onPaste={event => event.stopPropagation()}
      onDrop={event => event.stopPropagation()}>
      {editing && !readOnly ? (
        <form
          className="resource-form"
          onKeyDown={event => {
            if (composingKey(event.nativeEvent)) {
              if (event.key === 'Enter') event.preventDefault()
              return
            }
            if (event.key === 'Escape' && !busy) {
              event.preventDefault()
              finishEditing(true)
            }
          }}
          onSubmit={event => {
            event.preventDefault()
            save()
          }}>
          <strong>{label(`${kind}_title`)}</strong>
          {host?.uploadAsset && kind === 'media' && (
            <>
              <input
                ref={input}
                className="sr-only"
                type="file"
                aria-label={label('resource_upload')}
                accept={knowledge ? 'image/*' : 'image/*,video/*'}
                disabled={busy}
                onChange={event => {
                  const file = event.target.files?.[0]
                  event.target.value = ''
                  if (file) void upload(file)
                }}
              />
              <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => input.current?.click()}>
                {label(busy ? 'resource_uploading' : 'resource_upload')}
              </Button>
            </>
          )}
          <label>
            {label('resource_address')}
            <Input
              ref={addressInput}
              value={draft.src ?? ''}
              placeholder="https://"
              disabled={busy}
              onChange={event => setEdits({ ...edits, ...replaceResourceSource({ src: event.target.value }) })}
            />
          </label>
          <label>
            {label('resource_title')}
            <Input
              value={draft.title ?? ''}
              disabled={busy}
              onChange={event => setEdits({ ...edits, title: event.target.value })}
            />
          </label>
          {kind === 'bookmark' && (
            <>
              <label>
                {label('resource_description')}
                <Input
                  value={draft.description ?? ''}
                  onChange={event => setEdits({ ...edits, description: event.target.value })}
                />
              </label>
              <label>
                {label('resource_image')}
                <Input
                  value={draft.image ?? ''}
                  placeholder="https://"
                  onChange={event => setEdits({ ...edits, image: event.target.value })}
                />
              </label>
            </>
          )}
          {kind === 'media' && (
            <div role="group" aria-label={label('resource_kind')} className="resource-actions">
              {(knowledge ? (['image'] as const) : (['image', 'video'] as const)).map(value => (
                <Button
                  key={value}
                  type="button"
                  variant="ghost"
                  size="xs"
                  aria-pressed={mediaKind(draft) === value}
                  onClick={() => setEdits({ ...edits, kind: value })}>
                  {label(`resource_${value}_kind`)}
                </Button>
              ))}
            </div>
          )}
          {error && <p role="alert">{error}</p>}
          <div className="resource-actions">
            <Button type="submit" size="sm" disabled={busy}>
              {label('resource_apply')}
            </Button>
            <Button type="button" size="sm" variant="ghost" disabled={busy} onClick={() => finishEditing(true)}>
              {label('resource_cancel')}
            </Button>
          </div>
        </form>
      ) : (
        <>
          <div className="resource-toolbar">
            {!readOnly && !knowledge && kind !== 'embed' && (
              <DropdownMenu>
                <DropdownMenuTrigger render={<Button variant="ghost" size="xs" aria-label={label('resource_view')} />}>
                  {label(`resource_view_${view}`)}
                  <RiArrowDownSLine />
                </DropdownMenuTrigger>
                <DropdownMenuContent className="ankole-editor-overlay">
                  {views.map(value => (
                    <DropdownMenuItem key={value} onClick={() => update({ view: value })}>
                      {label(`resource_view_${value}`)}
                      {view === value && <RiCheckLine />}
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
            )}
            {!readOnly && (
              <Button
                variant="ghost"
                size="xs"
                onClick={() => {
                  pendingFocus.current = true
                  setEdits({})
                  setError('')
                  setEditing(true)
                }}>
                {label('resource_edit')}
              </Button>
            )}
            {src && (
              <a
                href={src}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={label('resource_open')}
                title={label('resource_open')}>
                <RiExternalLinkLine size={16} />
              </a>
            )}
          </div>
          {preview}
          {src ? (
            <a className="resource-summary" href={src} target="_blank" rel="noopener noreferrer">
              {view === 'card' && kind === 'bookmark' && attrs.image && webURL(attrs.image) && (
                <img className="resource-cover" src={webURL(attrs.image)!} alt="" loading="lazy" />
              )}
              {view !== 'preview' && <RiLink className="resource-symbol" />}
              <span className="resource-copy">
                <span className="resource-name">{view === 'link' ? attrs.src : title}</span>
                {view === 'card' && (
                  <>
                    {attrs.description && <span>{attrs.description}</span>}
                    <small>{resourceHostname(src)}</small>
                  </>
                )}
              </span>
            </a>
          ) : (
            <p className="resource-hint">{label(`${kind}_title`)}</p>
          )}
        </>
      )}
    </div>
  )
}
